defmodule Tab.Inbox.Receiving do
  @moduledoc """
  The part of receiving mail that happens before Tab knows whose it is
  (docs/specification.md, "Forwarded email"). These queries run as the
  connection owner because no person is signed in: the webhook records that
  mail arrived, and the fetch job matches it to a forwarding address. Once the
  person is known, everything else runs as them through `Tab.Inbox`.
  """
  import Ecto.Query

  alias Tab.Accounts.{Scope, User}
  alias Tab.Inbox
  alias Tab.Inbox.{Address, Email, FetchWorker, Message}
  alias Tab.Repo

  @doc """
  Records an `email.received` event and queues fetching it, together. A
  repeat of the same event changes nothing. Raises if the database can't take
  it, so the webhook answers 503 and Resend tries again.
  """
  def record(provider_id) when is_binary(provider_id) do
    Repo.transaction(fn ->
      {count, _} =
        Repo.insert_all(
          Message,
          [%{id: Ecto.UUID.generate(), provider: "resend", provider_id: provider_id}],
          on_conflict: :nothing,
          conflict_target: [:provider, :provider_id],
          returning: [:id]
        )

      if count == 1 do
        %Message{id: id} = Repo.get_by!(Message, provider: "resend", provider_id: provider_id)
        Oban.insert!(FetchWorker.new(%{message_id: id}))
      end

      :ok
    end)
  end

  @doc """
  Routes a message fetched some other way (`mix tab.mail.pull --route`) the
  same way the webhook's would be: recorded once, then matched to whoever's
  address it was sent to. `mail` is what `Tab.Inbox.Resend.fetch/2` returns.
  """
  def route(provider_id, mail) do
    Repo.insert_all(
      Message,
      [%{id: Ecto.UUID.generate(), provider: "resend", provider_id: provider_id}],
      on_conflict: :nothing,
      conflict_target: [:provider, :provider_id]
    )

    case Repo.get_by!(Message, provider: "resend", provider_id: provider_id) do
      %Message{status: "fetching"} = message ->
        :ok = store(message, mail)
        Repo.get!(Message, message.id)

      message ->
        message
    end
  end

  @doc "Gives up on a message Resend wouldn't hand over."
  def give_up(message_id) do
    Repo.get!(Message, message_id) |> finish(status: "failed", detail: "couldn't be fetched")
  end

  @doc "Fetches, matches, and stores one received message. Called by `Tab.Inbox.FetchWorker`."
  def fetch_and_store(message_id) do
    message = Repo.get!(Message, message_id)

    if message.status != "fetching" do
      :ok
    else
      case Inbox.Resend.fetch(message.provider_id, Inbox.max_bytes(:pdf)) do
        {:ok, mail} -> store(message, mail)
        {:error, :too_big} -> finish(message, status: "failed", detail: "too big to read")
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp store(message, mail) do
    base = [from_address: trunc(mail.from, 320), subject: trunc(mail.subject, 500)]

    case address_for(mail.to) do
      nil ->
        finish(message, [status: "unmatched"] ++ base)

      {user, group_id} ->
        scope = Scope.for_user(user)
        base = [user_id: user.id] ++ base

        case Email.parse(mail.raw) do
          {:ok, %Email{gmail_code: code}} when is_binary(code) ->
            finish(message, [status: "stored", kind: "gmail_check", detail: code] ++ base)

          _ ->
            doc = %{
              kind: "email",
              content_type: "message/rfc822",
              filename: nil,
              data: mail.raw,
              source: "email",
              group_id: group_id
            }

            case Inbox.add(scope, doc) do
              {:ok, _} ->
                finish(message, [status: "stored"] ++ base)

              {:error, :duplicate} ->
                finish(message, [status: "stored", detail: "already sent"] ++ base)

              {:error, _} ->
                finish(message, [status: "failed", detail: "couldn't be saved"] ++ base)
            end
        end
    end
  end

  defp finish(message, fields) do
    message |> Ecto.Changeset.change(fields) |> Repo.update!()
    :ok
  end

  defp trunc(nil, _), do: nil
  defp trunc(s, n), do: String.slice(s, 0, n)

  # The first recipient that's a live forwarding address on this server:
  # `{user, group_id}`, or nil.
  defp address_for(recipients) do
    domain = Inbox.inbound_domain()

    locals =
      for r <- recipients,
          addr = Email.address(r),
          is_binary(addr),
          [local, host] <- [String.split(addr, "@")],
          domain && host == String.downcase(domain),
          do: local |> String.split("+") |> hd()

    if locals == [] do
      nil
    else
      Repo.one(
        from a in Address,
          join: u in User,
          on: u.id == a.user_id,
          # Someone who left the group gets nothing from its address.
          join: m in "memberships",
          on: m.group_id == a.group_id and m.user_id == a.user_id and is_nil(m.left_at),
          where: a.local_part in ^locals and is_nil(a.revoked_at),
          select: {u, a.group_id},
          limit: 1
      )
    end
  end

  @doc """
  People with a digest due today and something to put in it: an item ready
  to check, or a group with a regular bill that might be late (the digest
  itself works out lateness, as the person).
  """
  def digest_recipients(today \\ Date.utc_today()) do
    Repo.all(
      from u in User,
        as: :user,
        join: p in "profiles",
        on: p.user_id == u.id,
        where:
          ^today.day in p.digest_days and
            (exists(
               from i in "pending_items",
                 where: i.user_id == parent_as(:user).id and i.status in ["ready", "unreadable"],
                 select: 1
             ) or
               exists(
                 from m in "memberships",
                   join: t in "recurring_templates",
                   on: t.group_id == m.group_id,
                   where:
                     m.user_id == parent_as(:user).id and is_nil(m.left_at) and
                       is_nil(t.deleted_at) and t.cadence != "irregular" and
                       not is_nil(t.last_logged_on),
                   select: 1
               )),
        select: u.id
    )
  end
end
