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
  # Stores a document and a pending item for it, then queues the reading.
  # Used by uploads and by received mail (as the person it was for). After
  # reading, the document may join another item about the same bill.
  def add(%Scope{} = scope, %{kind: kind, data: data} = doc) do
    sha = :crypto.hash(:sha256, data)
    ref = reference(kind, data)

    result =
      as_user(scope, fn ->
        if seen?(sha, ref.fingerprint) do
          {:error, :duplicate}
        else
          with {:ok, item} <-
                 Repo.insert(%Item{source: doc.source, group_id: doc[:group_id]}),
               {:ok, _} <-
                 Repo.insert(%Document{
                   item_id: item.id,
                   kind: kind,
                   content_type: doc.content_type,
                   filename: doc[:filename] && String.slice(doc.filename, 0, 255),
                   byte_size: byte_size(data),
                   sha256: sha,
                   content: data,
                   fingerprint: ref.fingerprint,
                   sender: ref.sender,
                   subject: ref.subject,
                   sent_at: ref.sent_at,
                   search: ref.search
                 }) do
            {:ok, item}
          end
        end
      end)

    with {:ok, item} <- result do
      {:ok, _} =
        Oban.insert(
          ReadWorker.new(%{item_id: item.id, user_id: scope.user.id},
            priority: Tab.Billing.read_priority(scope.user.id)
          )
        )

      {:ok, item}
    end
  end

  # The same file, or the same email forwarded again, in the last 90 days.
  defp seen?(sha, fingerprint) do
    since = DateTime.add(now(), -90, :day)
    q = from d in Document, where: d.inserted_at > ^since

    Repo.exists?(where(q, [d], d.sha256 == ^sha)) or
      (fingerprint != nil and Repo.exists?(where(q, [d], d.fingerprint == ^fingerprint)))
  end

  # Who sent an email, its subject and date, a fingerprint that survives
  # forwarding it again, and a line for searching for it in a mailbox.
  defp reference("email", data) do
    case Email.parse(data) do
      {:ok, %Email{sender: sender, original_subject: subject, sent_on: on}} ->
        fingerprint =
          if sender && subject && on,
            do: :crypto.hash(:sha256, Enum.join([sender, String.downcase(subject), on], "\n"))

        %{
          fingerprint: fingerprint,
          sender: sender && String.slice(sender, 0, 320),
          subject: subject && String.slice(subject, 0, 500),
          sent_at: on && NaiveDateTime.new!(on, ~T[00:00:00]),
          search: search(sender, subject, on)
        }

      _ ->
        %{fingerprint: nil, sender: nil, subject: nil, sent_at: nil, search: nil}
    end
  end

  defp reference(_, _),
    do: %{fingerprint: nil, sender: nil, subject: nil, sent_at: nil, search: nil}

  @doc ~S"""
  A search line for finding an email again in the mailbox it came from, in
  the form Gmail understands (and people can read).

      iex> Tab.Inbox.search("noreply@sfwater.org", "Your New SFPUC Water Bill!", ~D[2026-09-24])
      ~s|from:(noreply@sfwater.org) subject:("Your New SFPUC Water Bill!") after:2026/09/23 before:2026/09/26|
      iex> Tab.Inbox.search(nil, nil, nil)
      nil
  """
  def search(nil, nil, _), do: nil

  def search(sender, subject, on) do
    [
      sender && "from:(#{sender})",
      subject && ~s|subject:("#{String.replace(subject, "\"", "")}")|,
      on && "after:#{Calendar.strftime(Date.add(on, -1), "%Y/%m/%d")}",
      on && "before:#{Calendar.strftime(Date.add(on, 2), "%Y/%m/%d")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.slice(0, 1000)
  end

  ## Pending items

  @doc "Items still waiting on the person, newest first, with their documents' details (not their content)."
  def list_items(%Scope{} = scope) do
    as_user(scope, fn ->
      {:ok,
       Repo.all(
         from i in Item,
           where: i.status in @open,
           order_by: [desc: i.inserted_at],
           preload: [documents: ^document_meta()]
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
      found(Repo.one(from i in Item, where: i.id == ^id, preload: [documents: ^document_meta()]))
    end)
  end

  @meta [
    :id,
    :user_id,
    :item_id,
    :kind,
    :content_type,
    :filename,
    :byte_size,
    :role,
    :sender,
    :subject,
    :sent_at,
    :amount_cents,
    :search,
    :expense_id,
    :purged_at,
    :inserted_at
  ]

  defp document_meta do
    from d in Document,
      select: struct(d, ^@meta),
      order_by: [asc_nulls_last: d.sent_at, asc: d.inserted_at]
  end

  @doc """
  A document's bytes, if the person may see it and it's still there. Once its
  bill is saved or dropped, `{:error, :not_found}`: only the reference stays.
  """
  def content(%Scope{} = scope, document_id) do
    as_user(scope, fn ->
      case Repo.get(Document, document_id) do
        %Document{content: data} = d when is_binary(data) -> {:ok, d}
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc """
  What arrived about an expense's bill: kind, sender, subject, date, amount,
  and a search line. Everyone who can see the expense sees these; the
  originals themselves are gone.
  """
  def references(%Scope{} = scope, expense_id) do
    as_user(scope, fn ->
      {:ok, Repo.all(from d in document_meta(), where: d.expense_id == ^expense_id)}
    end)
  end

  @doc "Drops an item: it's not a bill, or not one to share. Its originals are deleted."
  def dismiss(%Scope{} = scope, id) do
    as_user(scope, fn ->
      with {:ok, item} <- found(Repo.get(Item, id)),
           true <- item.status in @open || {:error, :not_found},
           {:ok, item} <- item |> Ecto.Changeset.change(status: "dismissed") |> Repo.update() do
        purge(item.id)
        {:ok, item}
      end
    end)
  end

  @doc """
  Turns an item into an expense in `group_id`, with `attrs` as the form would
  pass to `Tab.Ledger.create_expense/3`. The item's originals are deleted;
  their references stay with the expense. Options:

    * `names: ["SFPUC", "sfwater.org"]` adds the names the bill came under
      to the expense's bill (its aliases), so Tab recognizes them next time,
    * `new_bill: true` makes a bill on the Bills page from the expense, with
      those names as its aliases.

  All of it happens together or not at all.
  """
  def confirm(%Scope{} = scope, %Item{} = item, group_id, attrs, opts \\ []) do
    Repo.transaction(fn ->
      with {:ok, expense} <- Ledger.create_expense(scope, group_id, attrs),
           {:ok, _} <- finish(scope, item, expense),
           {:ok, _} <- remember(scope, expense, opts) do
        expense
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp finish(scope, item, expense) do
    as_user(scope, fn ->
      with {:ok, item} <- found(Repo.get(Item, item.id)),
           true <- item.status in @open || {:error, :not_found},
           {:ok, item} <-
             item
             |> Ecto.Changeset.change(
               status: "confirmed",
               expense_id: expense.id,
               group_id: expense.group_id
             )
             |> Repo.update() do
        from(d in Document, where: d.item_id == ^item.id)
        |> Repo.update_all(set: [expense_id: expense.id, updated_at: now()])

        purge(item.id)
        {:ok, item}
      end
    end)
  end

  defp purge(item_id) do
    from(d in Document, where: d.item_id == ^item_id and not is_nil(d.content))
    |> Repo.update_all(set: [content: nil, updated_at: now()])
  end

  defp remember(scope, %Expense{template_id: tid} = expense, opts) when is_binary(tid) do
    with {:ok, _} <- Tab.Bills.add_aliases(scope, tid, opts[:names] || []), do: {:ok, expense}
  end

  defp remember(scope, expense, opts) do
    if opts[:new_bill] do
      Tab.Bills.create_template_from(scope, expense, opts[:names] || [])
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
  # The newest document's bytes and, for an email, the part worth reading.
  def reader_input(%Scope{} = scope, %Item{documents: [_ | _] = docs}) do
    with {:ok, d} <- content(scope, List.last(docs).id) do
      case d.kind do
        "email" ->
          with {:ok, email} <- Email.parse(d.content) do
            base = %{
              subject: email.original_subject || email.subject,
              from: email.sender || email.from
            }

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

  def reader_input(_, _), do: {:error, :not_found}

  @doc false
  # Saves what the reader found. The document then joins, in order: another
  # open item about the same bill, an expense someone already saved for it,
  # or stays in this item, ready to check. "The same bill" is the same company
  # and amount within 45 days, the same company and due date, or the same
  # amount and due date.
  def save_reading(%Scope{} = scope, %Item{} = item, proposal, sender) do
    broadcast(scope, do_save_reading(scope, item, proposal, sender))
  end

  defp do_save_reading(scope, item, proposal, sender) do
    as_user(scope, fn ->
      with {:ok, item} <-
             found(Repo.one(from i in Item, where: i.id == ^item.id, preload: :documents)) do
        forwarders = forwarders(item.group_id)

        proposal =
          Map.merge(proposal, %{
            "sender" => sender,
            "names" => names(proposal, sender, forwarders)
          })

        doc = List.last(item.documents)
        label(doc, proposal)
        template = match_template(proposal["names"], item.group_id)
        key = bill_key(proposal, item.group_id, doc, template && template.id)

        cond do
          other = same_open_item(item, key) -> join_item(item, doc, other, proposal)
          expense = same_expense(key) -> join_expense(item, doc, expense)
          true -> ready(item, proposal, template, forwarders)
        end
      end
    end)
  end

  # The forwarding addresses of the group, or of all the person's groups.
  defp forwarders(group_id) do
    q = from f in Tab.Bills.Forwarder, where: is_nil(f.deleted_at), select: f.address
    q = if group_id, do: where(q, [f], f.group_id == ^group_id), else: q
    q |> Repo.all() |> MapSet.new()
  end

  # The names a document gave its company: the merchant it names, and the
  # sender's domain unless the sender only forwards bills.
  defp names(p, sender, forwarders) do
    domain = if sender && !MapSet.member?(forwarders, sender), do: Email.domain(sender)
    Enum.reject([p["merchant"], domain], &is_nil/1)
  end

  defp label(nil, _), do: :ok

  defp label(doc, p) do
    from(d in Document, where: d.id == ^doc.id)
    |> Repo.update_all(
      set: [role: p["kind"], amount_cents: amount(p), reading: p, updated_at: now()]
    )
  end

  defp amount(p), do: p["period_cents"] || p["total_cents"]

  # What identifies a bill: who it's from, how much, and when.
  defp bill_key(p, group_id, doc, template_id) do
    %{
      companies: companies(p["names"] || []),
      template_id: template_id,
      amount: amount(p),
      due_on: p["due_on"],
      on:
        Enum.find_value(~w(due_on paid_on date), &(p[&1] && Date.from_iso8601!(p[&1]))) ||
          (doc && doc.sent_at && NaiveDateTime.to_date(doc.sent_at)) || Date.utc_today(),
      group_id: group_id
    }
  end

  @doc ~S"""
  Names squeezed for matching: a domain or address becomes the domain's main
  part; anything else keeps only its letters and digits.

      iex> Tab.Inbox.companies(["PG&E", "billpay.pge.com"])
      ["pge"]
      iex> Tab.Inbox.companies(["Recology Sunset Scavenger", "noreply@recology.com"])
      ["recologysunsetscavenger", "recology"]
  """
  def companies(names) do
    names
    |> Enum.map(&company/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp company(name) do
    cond do
      String.contains?(name, "@") ->
        name |> Email.domain() |> company()

      Regex.match?(~r/^[a-z0-9-]+(\.[a-z0-9-]+)+$/i, name) ->
        name |> String.downcase() |> Email.domain_of_host() |> String.split(".") |> hd()

      true ->
        squeeze(name)
    end
  end

  defp squeeze(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  # The same company when one name holds the other: "recology" and
  # "recologysunsetscavenger".
  defp same_company?(a, b) do
    pairs = for x <- a, y <- b, do: {x, y}

    Enum.any?(pairs, fn {x, y} ->
      String.length(x) >= 3 and String.length(y) >= 3 and
        (String.contains?(x, y) or String.contains?(y, x))
    end)
  end

  # Same company (or matched to the same bill) and amount within 45 days, or
  # same company and due date. The same amount due the same day is the same
  # bill even when the names differ.
  defp same_bill?(key, other) do
    company? =
      (key.template_id != nil and key.template_id == other.template_id) or
        same_company?(key.companies, other.companies)

    (company? and
       ((key.amount != nil and key.amount == other.amount and
           abs(Date.diff(key.on, other.on)) <= 45) or
          (key.due_on != nil and key.due_on == other.due_on))) or
      (key.amount != nil and key.due_on != nil and key.amount == other.amount and
         key.due_on == other.due_on)
  end

  defp same_open_item(item, key) do
    from(i in Item,
      where: i.id != ^item.id and i.status in ~w(ready unreadable waiting),
      preload: :documents
    )
    |> then(fn q ->
      if key.group_id,
        do: where(q, [i], i.group_id == ^key.group_id or is_nil(i.group_id)),
        else: q
    end)
    |> Repo.all()
    |> Enum.find(fn other ->
      same_bill?(
        key,
        bill_key(other.proposal, other.group_id, List.first(other.documents), other.template_id)
      )
    end)
  end

  defp same_expense(%{amount: nil}), do: nil

  defp same_expense(key) do
    q =
      from e in Expense,
        left_join: t in Template,
        on: t.id == e.template_id,
        where:
          is_nil(e.deleted_at) and e.visibility == "shared" and e.amount_cents == ^key.amount and
            e.date >= ^Date.add(key.on, -45) and e.date <= ^Date.add(key.on, 45),
        select: {e, t}

    q = if key.group_id, do: where(q, [e], e.group_id == ^key.group_id), else: q

    q
    |> Repo.all()
    |> Enum.find_value(fn {e, t} ->
      same_template? = key.template_id != nil and e.template_id == key.template_id
      names = [e.description | if(t, do: [t.name | t.aliases], else: [])]
      if same_template? or same_company?(companies(names), key.companies), do: e
    end)
  end

  # This document is about a bill already waiting to be checked: it joins it,
  # filling in what that one didn't say, and this item closes.
  defp join_item(item, doc, other, p) do
    from(d in Document, where: d.id == ^doc.id)
    |> Repo.update_all(set: [item_id: other.id, updated_at: now()])

    {:ok, _} = update_proposal(other, merge(other.proposal, p))
    close(item, "joined another bill")
  end

  defp update_proposal(item, merged) do
    item
    |> Ecto.Changeset.change(
      proposal: merged,
      status: if(item.status == "unreadable" and merged["kind"], do: "ready", else: item.status),
      due_on: merged["due_on"] && Date.from_iso8601!(merged["due_on"]),
      doc_type: merged["doc_type"] || item.doc_type
    )
    |> Repo.update()
  end

  # This document is about a bill someone already saved: it goes with that
  # expense as a reference, and this item closes.
  defp join_expense(item, doc, expense) do
    from(d in Document, where: d.id == ^doc.id)
    |> Repo.update_all(set: [expense_id: expense.id, updated_at: now()])

    purge(item.id)
    close(item, "added to #{String.slice(expense.description, 0, 80)}")
  end

  defp close(item, note) do
    item |> Ecto.Changeset.change(status: "merged", note: note, read_at: now()) |> Repo.update()
  end

  # Fields the item doesn't have yet come from the new document; a full
  # bill's fields win; past due sticks once any document says so; names add up.
  @doc false
  def merge(old, new) do
    base =
      if new["kind"] == "bill",
        do: Map.merge(old, reject_nil(new)),
        else: Map.merge(reject_nil(new), reject_nil(old))

    base
    |> Map.put("past_due", old["past_due"] == true or new["past_due"] == true)
    |> Map.put("kind", if(new["kind"] == "bill", do: "bill", else: old["kind"] || new["kind"]))
    |> Map.put("names", Enum.uniq((old["names"] || []) ++ (new["names"] || [])))
  end

  defp reject_nil(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp ready(item, proposal, template, forwarders) do
    proposal =
      case forwarder_hint(proposal, forwarders) do
        nil -> proposal
        sender -> Map.put(proposal, "suggest_forwarder", sender)
      end

    item
    |> Ecto.Changeset.change(
      status: "ready",
      doc_type: proposal["doc_type"],
      proposal: proposal,
      due_on: proposal["due_on"] && Date.from_iso8601!(proposal["due_on"]),
      template_id: template && template.id,
      group_id: item.group_id || (template && template.group_id) || only_group(),
      duplicate_of: duplicate(proposal),
      read_at: now()
    )
    |> Repo.update()
  end

  # An address that has sent bills naming two different companies is
  # probably someone forwarding them, like a landlord: suggest it.
  defp forwarder_hint(%{"sender" => sender, "merchant" => merchant}, forwarders)
       when is_binary(sender) and is_binary(merchant) do
    if MapSet.member?(forwarders, sender) do
      nil
    else
      mine = companies([merchant])

      from(d in Document, where: d.sender == ^sender and not is_nil(d.reading), select: d.reading)
      |> Repo.all()
      |> Enum.any?(fn r ->
        is_binary(r["merchant"]) and not same_company?(companies([r["merchant"]]), mine)
      end)
      |> if(do: sender)
    end
  end

  defp forwarder_hint(_, _), do: nil

  ## Fixing grouping by hand

  @doc """
  Puts two bills to check together: `item_id`'s documents join `target_id`,
  whose details are worked out again from all its documents. If the target
  is matched to a bill on the Bills page, the other one's names become
  aliases of it, so next time Tab puts them together itself.
  """
  def join(%Scope{} = scope, item_id, target_id) when item_id != target_id do
    broadcast(
      scope,
      as_user(scope, fn ->
        open =
          from i in Item, where: i.status in ~w(ready unreadable waiting), preload: :documents

        with {:ok, item} <- found(Repo.get(open, item_id)),
             {:ok, target} <- found(Repo.get(open, target_id)) do
          from(d in Document, where: d.item_id == ^item.id)
          |> Repo.update_all(set: [item_id: target.id, updated_at: now()])

          {:ok, target} = rebuild(target)
          {:ok, _} = close(item, "put together by hand")

          if target.template_id,
            do:
              {:ok, _} =
                Tab.Bills.add_aliases(scope, target.template_id, item.proposal["names"] || [])

          {:ok, target}
        end
      end)
    )
  end

  def join(_, _, _), do: {:error, :not_found}

  @doc """
  Takes one document out of a bill to check and makes it a bill of its own.
  Both bills' details are worked out again from their documents.
  """
  def split(%Scope{} = scope, item_id, document_id) do
    broadcast(
      scope,
      as_user(scope, fn ->
        with {:ok, item} <-
               found(
                 Repo.one(
                   from i in Item,
                     where: i.id == ^item_id and i.status in ~w(ready unreadable waiting),
                     preload: :documents
                 )
               ),
             true <- length(item.documents) > 1 || {:error, :only_document},
             true <- Enum.any?(item.documents, &(&1.id == document_id)) || {:error, :not_found},
             {:ok, new} <-
               Repo.insert(%Item{source: item.source, group_id: item.group_id, status: "ready"}) do
          from(d in Document, where: d.id == ^document_id)
          |> Repo.update_all(set: [item_id: new.id, updated_at: now()])

          {:ok, _} = rebuild(item)
          {:ok, new} = rebuild(new)

          template = match_template(new.proposal["names"] || [], new.group_id)

          new
          |> Ecto.Changeset.change(template_id: template && template.id, read_at: now())
          |> Repo.update()
        end
      end)
    )
  end

  # Works an item's details out again from what was read in each document.
  defp rebuild(item) do
    readings =
      from(d in Document,
        where: d.item_id == ^item.id and not is_nil(d.reading),
        order_by: [asc_nulls_last: d.sent_at, asc: d.inserted_at],
        select: d.reading
      )
      |> Repo.all()

    case readings do
      [] ->
        item
        |> Ecto.Changeset.change(status: "unreadable", proposal: Tab.Inbox.Proposal.blank())
        |> Repo.update()

      [first | rest] ->
        merged = Enum.reduce(rest, first, &merge(&2, &1))
        update_proposal(%{item | status: "ready"}, merged)
    end
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

  # The bill on the Bills page this document's names match: its name or
  # any of its aliases.
  defp match_template(names, group_id) do
    keys = companies(names || [])

    if keys == [] do
      nil
    else
      live = from t in Template, where: is_nil(t.deleted_at)
      live = if group_id, do: where(live, [t], t.group_id == ^group_id), else: live

      live
      |> Repo.all()
      |> Enum.find(&same_company?(companies([&1.name | &1.aliases]), keys))
    end
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
