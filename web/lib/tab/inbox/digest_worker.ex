defmodule Tab.Inbox.DigestWorker do
  @moduledoc "Runs each morning at 9:00 server time and queues the day's digests."
  use Oban.Worker, queue: :mail, max_attempts: 3

  @impl Oban.Worker
  def perform(_job), do: Tab.Inbox.Mail.enqueue_digests()
end
