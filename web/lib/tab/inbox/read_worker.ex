defmodule Tab.Inbox.ReadWorker do
  @moduledoc """
  Reads one pending item with `Tab.Reader`, as the person it belongs to.

  On Hosted Tab, the person's plan decides first (`Tab.Billing`): Hosted free
  reads nothing (the item is filled in by hand), and past the month's
  allowance the item waits for the 1st. Past the day's limit
  (`TAB_READS_PER_DAY`) the item waits for tomorrow. With
  the API account out of credit, it waits for tomorrow too. With
  the reader off, or after it fails to make sense of a document, the item is
  marked unreadable: its person types it in by hand beside the original. A
  reader that can't be reached gets a few more tries first.
  """
  use Oban.Worker, queue: :read, max_attempts: 4

  alias Tab.Accounts.{Scope, User}
  alias Tab.Inbox
  alias Tab.Inbox.{Email, Item, Mail, Proposal}
  alias Tab.{Billing, Reader, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"item_id" => item_id, "user_id" => user_id}} = job) do
    with %User{} = user <- Repo.get(User, user_id),
         scope = Scope.for_user(user),
         {:ok, %Item{status: status} = item} when status in ~w(reading waiting) <-
           Inbox.get_item(scope, item_id) do
      read(scope, item, job)
    else
      _ -> :ok
    end
  end

  defp read(scope, item, job) do
    {:ok, today} = Inbox.reads_today(scope)

    case Billing.may_read(scope.user.id) do
      {:error, :no_plan} ->
        unreadable(scope, item, "Tab reads bills on Plus; fill this one in yourself")

      {:error, {:limit, resumes_on}} ->
        wait_until(
          scope,
          item,
          job,
          resumes_on,
          "reading paused until #{Calendar.strftime(resumes_on, "%b %-d")}"
        )

      {:ok, paid?} ->
        if today >= limit() do
          wait(scope, item, job, "waiting for tomorrow's reading")
        else
          case Inbox.reader_input(scope, item) do
            {:ok, input, email} -> ask(scope, item, input, sender(email), job, paid?)
            _ -> unreadable(scope, item, "couldn't open this one")
          end
        end
    end
  end

  defp ask(scope, item, input, sender, job, paid?) do
    result = Reader.read(input)

    # The model looked at it, so it counts toward the month.
    if match?({:ok, _}, result) or result == {:error, :unreadable},
      do: Billing.record_read(scope.user.id, nil, paid?)

    case result do
      {:ok, fields} ->
        {:ok, item} = Inbox.save_reading(scope, item, Proposal.validate(fields), sender)
        # A document that joined another bill or a saved expense says nothing new.
        if item.status == "ready", do: Mail.maybe_due_soon(scope, item), else: :ok

      # Out of API credit: try again tomorrow; it refills each month.
      {:error, :paused} ->
        wait(scope, item, job, "bill reading is paused; Tab tries again tomorrow")

      {:error, :off} ->
        unreadable(scope, item, "bill reading is off on this server")

      {:error, :unreadable} ->
        unreadable(scope, item, "couldn't read this one")

      {:error, :unreachable} ->
        if job.attempt >= job.max_attempts,
          do: unreadable(scope, item, "the reader didn't answer"),
          else: {:error, :unreachable}
    end
  end

  defp wait(scope, item, job, note),
    do: wait_until(scope, item, job, Date.add(Date.utc_today(), 1), note)

  defp wait_until(scope, item, job, %Date{} = day, note) do
    {:ok, _} = Inbox.mark(scope, item, "waiting", note)
    at = DateTime.new!(day, ~T[00:05:00])
    {:ok, _} = Oban.insert(new(job.args, scheduled_at: at, priority: job.priority))
    :ok
  end

  defp unreadable(scope, item, note) do
    {:ok, _} = Inbox.mark(scope, item, "unreadable", note)
    :ok
  end

  defp sender(%Email{sender: sender}), do: sender
  defp sender(_), do: nil

  defp limit, do: Application.get_env(:tab, :reads_per_day, 30)
end
