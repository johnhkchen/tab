defmodule Tab.Notifications do
  @moduledoc """
  Emails about the ledger (docs/specification.md, "Email notifications"):

    * a new shared expense you're part of,
    * a change to the amount or split of one you're part of,
    * a payment waiting for you to confirm it arrived.

  One email per person involved, never to whoever caused it. Each is an Oban
  job, so a slow mail service never holds up a page. The job builds the email
  as the recipient (through `Tab.Repo.as_user/2`), so it can only say what
  they're allowed to see.

  Jobs are enqueued after the ledger write commits, as the connection owner:
  people's own role can't touch the job table.
  """
  alias Tab.Accounts.Scope
  alias Tab.Ledger.{Expense, Payment}
  alias Tab.Notifications.Worker

  def expense_added(%Scope{} = scope, %Expense{visibility: "shared"} = e),
    do: enqueue("expense_added", scope, e.group_id, e.id, share_users(e))

  def expense_added(_, _), do: :ok

  def expense_changed(%Scope{} = scope, %Expense{visibility: "shared"} = e),
    do: enqueue("expense_changed", scope, e.group_id, e.id, share_users(e))

  def expense_changed(_, _), do: :ok

  def payment_pending(%Scope{} = scope, %Payment{status: "pending", to_user_id: to} = p)
      when is_binary(to),
      do: enqueue("payment_pending", scope, p.group_id, p.id, [to])

  def payment_pending(_, _), do: :ok

  defp share_users(%Expense{shares: shares}) when is_list(shares) do
    for %{user_id: id} <- shares, id, do: id
  end

  defp enqueue(event, %Scope{user: actor}, group_id, record_id, recipients) do
    recipients
    |> Enum.uniq()
    |> Enum.reject(&(&1 == actor.id))
    |> Enum.map(fn recipient ->
      Worker.new(%{
        event: event,
        group_id: group_id,
        record_id: record_id,
        actor_id: actor.id,
        recipient_id: recipient
      })
    end)
    |> Oban.insert_all()

    :ok
  end
end
