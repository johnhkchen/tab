defmodule Tab.Ledger.AuditEntry do
  @moduledoc "One change in a group's history, written by a database trigger. Read-only."
  use Tab.Schema

  schema "audit_log" do
    field :group_id, :binary_id
    field :table_name, :string
    field :row_id, :binary_id
    field :action, :string
    field :actor_id, :binary_id
    field :before, :map
    field :after, :map
    field :private_owner_id, :binary_id
    field :at, :utc_datetime
  end
end
