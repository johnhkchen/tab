defmodule Tab.OAuth.RateLimit do
  @moduledoc """
  Fixed-window counters in ETS: tool calls per connection per minute, client
  registrations per IP per day. Counts live in memory, so a restart resets
  them; that's fine for limits meant to stop runaway loops, not to bill.
  """
  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Counts one hit on `key` in a window of `seconds`. `:ok` while at most
  `limit` hits, else `{:error, seconds_left}`.
  """
  def hit(key, limit, seconds, now \\ System.system_time(:second)) do
    window = div(now, seconds)
    slot = {key, seconds, window}
    count = :ets.update_counter(@table, slot, 1, {slot, 0})

    if count <= limit, do: :ok, else: {:error, (window + 1) * seconds - now}
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(:timer.minutes(10), :sweep)
    {:ok, nil}
  end

  # Drops windows that have ended.
  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    :ets.select_delete(@table, [
      {{{:_, :"$1", :"$2"}, :_}, [{:<, {:*, {:+, :"$2", 1}, :"$1"}, now}], [true]}
    ])

    {:noreply, state}
  end
end
