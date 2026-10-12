defmodule Tab.Inbox.FetchWorker do
  @moduledoc "Fetches one received email from Resend and turns it into a pending item."
  use Oban.Worker,
    queue: :inbox,
    max_attempts: 10,
    unique: [keys: [:message_id], period: :infinity]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => id}} = job) do
    case Tab.Inbox.Receiving.fetch_and_store(id) do
      {:error, _} = error ->
        if job.attempt >= job.max_attempts, do: Tab.Inbox.Receiving.give_up(id), else: error

      :ok ->
        :ok
    end
  end
end
