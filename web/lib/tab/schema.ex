defmodule Tab.Schema do
  @moduledoc """
  Defaults for Tab's schemas: UUID keys generated client-side (so inserts need
  no `RETURNING`, see the ledger migration) and UTC second-precision timestamps.
  """
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
