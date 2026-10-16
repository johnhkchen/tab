defmodule Tab.OAuth.SweepWorker do
  @moduledoc "Runs nightly and clears registered clients nobody connected (`Tab.OAuth.sweep_clients/1`)."
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    Tab.OAuth.sweep_clients()
    :ok
  end
end
