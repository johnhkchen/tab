defmodule Tab.Inbox do
  @moduledoc """
  Bills sent to Tab to read (docs/specification.md, "Phase 4"): forwarding
  addresses, uploads, pending items, and turning a checked item into an
  expense.

  Everything here runs as the person (`Tab.DBError.as_user/2`). Receiving mail
  happens before anyone is known; that part lives in `Tab.Inbox.Receiving`.
  Nothing becomes an expense without `confirm/5`, which goes through
  `Tab.Ledger.create_expense/3` like an expense typed in by hand.
  """
  import Ecto.Query
  import Tab.DBError, only: [as_user: 2]
  import Tab.Groups, only: [found: 1, now: 0]

  alias Tab.Accounts.Scope
  alias Tab.Bills.Template
  alias Tab.Groups.Group
  alias Tab.Inbox.{Address, Document, Email, Item, Message, ReadWorker}
  alias Tab.Ledger.Expense
  alias Tab.{Ledger, Repo}

  @open ~w(reading ready unreadable waiting)
  @pdf_max 10 * 1024 * 1024
  @photo_max 2 * 1024 * 1024
  @photo_types ~w(image/jpeg image/png image/webp image/gif)

  def open_statuses, do: @open
  def max_bytes(:pdf), do: @pdf_max
  def max_bytes(:photo), do: @photo_max

  ## Forwarding addresses

  @doc "The domain forwarding addresses live on, or nil when mail isn't set up."
  def inbound_domain do
    case Application.get_env(:tab, :inbound_domain) do
      d when is_binary(d) and d != "" -> d
      _ -> nil
    end
  end

  @doc """
  Whether this server has addresses to forward to. Mail arrives through
  Resend's webhook (which also needs `RESEND_WEBHOOK_SECRET`) or, in
  development, `mix tab.mail.pull`.
  """
  def mail_enabled?, do: inbound_domain() != nil

  @doc """
  The person's live address for a group, made the first time it's asked for.
  Each person has their own for each group they're in.
  """
  def address(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      case Repo.one(from a in Address, where: a.group_id == ^group_id and is_nil(a.revoked_at)) do
        nil -> insert_address(group_id)
        a -> {:ok, a}
      end
    end)
  end

  @doc "Retires the live address for a group and makes a new one. Mail to the old one stops landing."
  def new_address(%Scope{} = scope, group_id) do
    as_user(scope, fn ->
      from(a in Address, where: a.group_id == ^group_id and is_nil(a.revoked_at))
      |> Repo.update_all(set: [revoked_at: now(), updated_at: now()])

      insert_address(group_id)
    end)
  end

  defp insert_address(group_id) do
    with {:ok, group} <- found(Repo.get(Group, group_id)) do
      Repo.insert(%Address{group_id: group_id, local_part: local_part(group.name)})
    end
  end

  @doc ~S"""
  A readable, private address: the group's name, then a random 10-letter tag.
  Only the tag keeps strangers out; the name is there so you can tell your
  addresses apart.

      iex> Regex.match?(~r/^elm-street-house-[a-z2-7]{10}$/, Tab.Inbox.local_part("Elm Street house!"))
      true
      iex> Regex.match?(~r/^creme-brulee-[a-z2-7]{10}$/, Tab.Inbox.local_part("Crème brûlée"))
      true
      iex> Regex.match?(~r/^group-[a-z2-7]{10}$/, Tab.Inbox.local_part("🏠"))
      true
  """
  def local_part(name) do
    slug =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 40)
      |> String.trim("-")

    tag =
      :crypto.strong_rand_bytes(10)
      |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, 10)

    "#{if slug == "", do: "group", else: slug}-#{tag}"
  end

  @doc "`local@domain`, or nil when mail isn't set up."
  def address_text(%Address{local_part: local}) do
    if domain = inbound_domain(), do: "#{local}@#{domain}"
  end

  @doc "The last few emails received for this person, newest first."
  def recent_mail(%Scope{} = scope, limit \\ 5) do
    as_user(scope, fn ->
      {:ok, Repo.all(from m in Message, order_by: [desc: m.received_at], limit: ^limit)}
    end)
  end

  ## Uploads

  @doc """
  Saves an uploaded photo or PDF and queues it for reading. `{:error, reason}`
  for `:wrong_type`, `:too_big`, or `:duplicate` (sent in the last 90 days).
  """
  def upload(%Scope{} = scope, %{content_type: type, data: data} = file) when is_binary(data) do
    with {:ok, kind} <- kind(type, byte_size(data)),
         true <- looks_like?(type, data) || {:error, :wrong_type} do
      add(scope, %{
        kind: kind,
        content_type: type,
        filename: file[:filename],
        data: data,
        source: "upload"
      })
    end
  end

  defp kind("application/pdf", size) when size <= @pdf_max, do: {:ok, "pdf"}
  defp kind(type, size) when type in @photo_types and size <= @photo_max, do: {:ok, "photo"}
  defp kind(type, _) when type in ["application/pdf" | @photo_types], do: {:error, :too_big}
  defp kind(_, _), do: {:error, :wrong_type}

  # The bytes must be what the type says, since originals are shown back.
  @doc false
  def looks_like?("application/pdf", <<"%PDF-", _::binary>>), do: true
  def looks_like?("image/jpeg", <<0xFF, 0xD8, 0xFF, _::binary>>), do: true
  def looks_like?("image/png", <<0x89, "PNG", _::binary>>), do: true
  def looks_like?("image/gif", <<"GIF8", _::binary>>), do: true
  def looks_like?("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: true
  def looks_like?(_, _), do: false

  @doc false
  # Stores a document and its pending item, then queues the reading. Used by
  # uploads and by received mail (as the person it was for).
  def add(%Scope{} = scope, %{kind: kind, data: data} = doc) do
    sha = :crypto.hash(:sha256, data)

    result =
      as_user(scope, fn ->
        since = DateTime.add(now(), -90, :day)

        if Repo.exists?(from d in Document, where: d.sha256 == ^sha and d.inserted_at > ^since) do
          {:error, :duplicate}
        else
          document = %Document{
            kind: kind,
            content_type: doc.content_type,
            filename: doc[:filename] && String.slice(doc.filename, 0, 255),
            byte_size: byte_size(data),
            sha256: sha,
            content: data
          }

          with {:ok, d} <- Repo.insert(document),
               {:ok, item} <-
                 Repo.insert(%Item{
                   document_id: d.id,
                   source: doc.source,
                   group_id: doc[:group_id]
                 }) do
            {:ok, item}
          end
        end
      end)

    with {:ok, item} <- result do
      {:ok, _} = Oban.insert(ReadWorker.new(%{item_id: item.id, user_id: scope.user.id}))
      {:ok, item}
    end
  end

  ## Pending items

  @doc "Items still waiting on the person, newest first, with their document's details (not its content)."
  def list_items(%Scope{} = scope) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from i in Item,
           where: i.status in @open,
           order_by: [desc: i.inserted_at],
           preload: [document: ^document_meta()]
       )}
    end)
  end

  @doc "How many items are ready to check."
  def ready_count(%Scope{} = scope) do
    as_user(scope, fn ->
      {:ok, Repo.aggregate(from(i in Item, where: i.status in ~w(ready unreadable)), :count)}
    end)
  end

  def get_item(%Scope{} = scope, id) do
    as_user(scope, fn ->
      found(Repo.one(from i in Item, where: i.id == ^id, preload: [document: ^document_meta()]))
    end)
  end

  defp document_meta do
    from d in Document,
      select:
        struct(d, [
          :id,
          :user_id,
          :kind,
          :content_type,
          :filename,
          :byte_size,
          :expense_id,
          :purged_at,
          :inserted_at
        ])
  end

  @doc """
  A document's bytes, if the person may see it: their own, or one kept with an
  expense they can see. `{:error, :not_found}` once purged.
  """
  def content(%Scope{} = scope, document_id) do
    as_user(scope, fn ->
      case Repo.get(Document, document_id) do
        %Document{content: data} = d when is_binary(data) -> {:ok, d}
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc "The documents kept with an expense (details only)."
  def kept_documents(%Scope{} = scope, expense_id) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from d in document_meta(),
           where: d.expense_id == ^expense_id and is_nil(d.purged_at),
           order_by: d.inserted_at
       )}
    end)
  end

  @doc "Drops an item: it's not a bill, or not one to share. Its original is deleted."
  def dismiss(%Scope{} = scope, id) do
    as_user(scope, fn ->
      with {:ok, item} <- found(Repo.get(Item, id)),
           true <- item.status in @open || {:error, :not_found},
           {:ok, item} <- item |> Ecto.Changeset.change(status: "dismissed") |> Repo.update(),
           :ok <- purge(item.document_id) do
        {:ok, item}
      end
    end)
  end

  @doc """
  Turns an item into an expense in `group_id`, with `attrs` as the form would
  pass to `Tab.Ledger.create_expense/3`. Options:

    * `keep: true` keeps the original with the expense instead of deleting it,
    * `sender: "pge.com"` remembers the sender on the expense's template,
    * `new_bill: true` makes a template from the expense (with the sender).

  All of it happens together or not at all.
  """
  def confirm(%Scope{} = scope, %Item{} = item, group_id, attrs, opts \\ []) do
    Repo.transaction(fn ->
      with {:ok, expense} <- Ledger.create_expense(scope, group_id, attrs),
           {:ok, _} <- finish(scope, item, expense, opts),
           {:ok, _} <- remember(scope, expense, opts) do
        expense
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp finish(scope, item, expense, opts) do
    as_user(scope, fn ->
      with {:ok, item} <- found(Repo.get(Item, item.id)),
           true <- item.status in @open || {:error, :not_found},
           {:ok, item} <-
             item
             |> Ecto.Changeset.change(
               status: "confirmed",
               expense_id: expense.id,
               group_id: group_id(expense)
             )
             |> Repo.update(),
           :ok <- keep_or_purge(item.document_id, expense, opts[:keep]) do
        {:ok, item}
      end
    end)
  end

  defp group_id(%Expense{group_id: id}), do: id

  defp keep_or_purge(document_id, expense, true) do
    from(d in Document, where: d.id == ^document_id and not is_nil(d.content))
    |> Repo.update_all(set: [expense_id: expense.id, updated_at: now()])

    :ok
  end

  defp keep_or_purge(document_id, _, _), do: purge(document_id)

  defp purge(document_id) do
    from(d in Document, where: d.id == ^document_id and not is_nil(d.content))
    |> Repo.update_all(set: [content: nil, updated_at: now()])

    :ok
  end

  defp remember(scope, %Expense{template_id: tid} = expense, opts) when is_binary(tid) do
    case opts[:sender] do
      sender when is_binary(sender) ->
        as_user(scope, fn ->
          from(t in Template, where: t.id == ^tid and is_nil(t.sender))
          |> Repo.update_all(set: [sender: sender, updated_at: now()])

          {:ok, expense}
        end)

      _ ->
        {:ok, expense}
    end
  end

  defp remember(scope, expense, opts) do
    if opts[:new_bill] do
      Tab.Bills.create_template_from(scope, expense, opts[:sender])
    else
      {:ok, expense}
    end
  end

  ## Live updates

  @doc "Subscribes the caller to changes in the person's inbox."
  def subscribe(%Scope{user: user}), do: Phoenix.PubSub.subscribe(Tab.PubSub, "inbox:" <> user.id)

  @doc false
  def broadcast(%Scope{user: user}, result) do
    Phoenix.PubSub.broadcast(Tab.PubSub, "inbox:" <> user.id, :inbox_changed)
    result
  end

  ## Reading (called by `Tab.Inbox.ReadWorker`)

  @doc false
  def reads_today(%Scope{} = scope) do
    start = DateTime.new!(Date.utc_today(), ~T[00:00:00])

    as_user(scope, fn ->
      {:ok, Repo.aggregate(from(i in Item, where: i.read_at >= ^start), :count)}
    end)
  end

  @doc false
  # The document's bytes and, for an email, the part worth reading.
  def reader_input(%Scope{} = scope, %Item{document_id: id}) do
    with {:ok, d} <- content(scope, id) do
      case d.kind do
        "email" ->
          with {:ok, email} <- Email.parse(d.content) do
            base = %{subject: email.subject, from: email.from}

            case email.part do
              {kind, type, _name, data} ->
                {:ok,
                 Map.merge(base, %{
                   kind: to_string(kind),
                   content_type: type,
                   content: data,
                   text: nil
                 }), email}

              nil ->
                {:ok,
                 Map.merge(base, %{
                   kind: "email",
                   content_type: "text/plain",
                   content: "",
                   text: email.text
                 }), email}
            end
          end

        kind ->
          {:ok, %{kind: kind, content_type: d.content_type, content: d.content}, nil}
      end
    end
  end

  @doc false
  # Saves what the reader proposed, with the template it matches, the group to
  # suggest, and any likely duplicate.
  def save_reading(%Scope{} = scope, %Item{} = item, proposal, sender) do
    broadcast(scope, do_save_reading(scope, item, proposal, sender))
  end

  defp do_save_reading(scope, item, proposal, sender) do
    as_user(scope, fn ->
      with {:ok, item} <- found(Repo.get(Item, item.id)) do
        template = match_template(proposal["merchant"], sender, item.group_id)

        item
        |> Ecto.Changeset.change(
          status: "ready",
          doc_type: proposal["doc_type"],
          proposal: Map.put(proposal, "sender", sender),
          due_on: proposal["due_on"] && Date.from_iso8601!(proposal["due_on"]),
          template_id: template && template.id,
          group_id: item.group_id || (template && template.group_id) || only_group(),
          duplicate_of: duplicate(proposal),
          read_at: now()
        )
        |> Repo.update()
      end
    end)
  end

  @doc false
  def mark(%Scope{} = scope, %Item{} = item, status, note)
      when status in ~w(unreadable waiting) do
    broadcast(scope, do_mark(scope, item, status, note))
  end

  defp do_mark(scope, item, status, note) do
    as_user(scope, fn ->
      with {:ok, item} <- found(Repo.get(Item, item.id)) do
        sender = item.proposal["sender"]

        item
        |> Ecto.Changeset.change(
          status: status,
          note: note,
          proposal:
            if(status == "unreadable",
              do: Map.put(Tab.Inbox.Proposal.blank(), "sender", sender),
              else: item.proposal
            ),
          group_id: item.group_id || only_group(),
          read_at: if(status == "unreadable", do: now(), else: item.read_at)
        )
        |> Repo.update()
      end
    end)
  end

  # By sender first (what someone confirmed before), then by name.
  defp match_template(merchant, sender, group_id) do
    live = from t in Template, where: is_nil(t.deleted_at)
    live = if group_id, do: where(live, [t], t.group_id == ^group_id), else: live
    domain = Email.domain(sender)

    by_sender =
      sender &&
        Repo.one(
          from t in live, where: t.sender in ^Enum.reject([sender, domain], &is_nil/1), limit: 1
        )

    by_sender || (merchant && by_name(live, merchant))
  end

  defp by_name(live, merchant) do
    m = String.downcase(merchant)

    Repo.all(live)
    |> Enum.find(fn t ->
      n = String.downcase(t.name)
      String.length(n) >= 3 and (String.contains?(m, n) or String.contains?(n, m))
    end)
  end

  defp only_group do
    case Repo.all(from g in Group, where: is_nil(g.deleted_at), select: g.id) do
      [id] -> id
      _ -> nil
    end
  end

  defp duplicate(%{"total_cents" => total, "date" => date})
       when is_integer(total) and is_binary(date) do
    d = Date.from_iso8601!(date)

    Repo.one(
      from e in Expense,
        where:
          e.amount_cents == ^total and is_nil(e.deleted_at) and
            e.date >= ^Date.add(d, -5) and e.date <= ^Date.add(d, 5),
        select: e.id,
        limit: 1
    )
  end

  defp duplicate(_), do: nil
end
