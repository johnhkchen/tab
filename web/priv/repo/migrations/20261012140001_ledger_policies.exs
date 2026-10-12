defmodule Tab.Repo.Migrations.LedgerPolicies do
  @moduledoc """
  Grants and row-level security for every person-facing table
  (docs/specification.md, "Row-level security, table by table").

  Each table starts from nothing (`REVOKE ALL`), gets only the privileges the
  spec allows (column lists on UPDATE pin what may change), and has one policy
  per verb. Verbs nobody may use still get a policy that refuses, so no verb is
  ever left to a default. `tab_user` never gets DELETE.
  """
  use Ecto.Migration

  # table => {grants, %{select:, insert:, update: {using, check}, delete:}}
  # A policy of nil means "refuse": USING (false) / WITH CHECK (false).
  @policies [
    users: {
      ["SELECT"],
      %{select: "id = auth.uid()", insert: nil, update: nil}
    },
    users_tokens: {
      [],
      %{select: nil, insert: nil, update: nil}
    },
    profiles: {
      ["SELECT", "UPDATE (display_name, payment_methods, reminder_channel, updated_at)"],
      %{
        select: "user_id = auth.uid() OR auth.shares_group(user_id)",
        insert: nil,
        update: {"user_id = auth.uid()", "user_id = auth.uid()"}
      }
    },
    groups: {
      ["SELECT", "INSERT", "UPDATE (name, deleted_at, updated_at)"],
      %{
        select: "auth.is_member(id)",
        insert: "auth.uid() IS NOT NULL AND created_by = auth.uid()",
        update: {"auth.is_admin(id)", "auth.is_admin(id)"}
      }
    },
    memberships: {
      ["SELECT", "UPDATE (role, left_at, updated_at)"],
      %{
        # Your own rows stay visible after you leave, so you can see that you did.
        select: "auth.is_member(group_id) OR user_id = auth.uid()",
        insert: nil,
        update:
          {"auth.is_admin(group_id) OR (user_id = auth.uid() AND left_at IS NULL)",
           "auth.is_admin(group_id) OR user_id = auth.uid()"}
      }
    },
    invites: {
      ["SELECT", "INSERT", "UPDATE (revoked_at, updated_at)"],
      %{
        select: "auth.is_admin(group_id)",
        insert: "auth.is_admin(group_id) AND created_by = auth.uid()",
        update: {"auth.is_admin(group_id)", "auth.is_admin(group_id)"}
      }
    },
    counterparties: {
      ["SELECT", "INSERT", "UPDATE (name, contact_email, notes, deleted_at, updated_at)"],
      %{
        select: "auth.is_member(group_id)",
        insert: "auth.is_member(group_id) AND created_by = auth.uid()",
        update: {"auth.is_member(group_id)", "auth.is_member(group_id)"}
      }
    },
    categories: {
      ["SELECT", "INSERT", "UPDATE (name, deleted_at, updated_at)"],
      %{
        select: "auth.is_member(group_id)",
        insert: "auth.is_member(group_id) AND created_by = auth.uid()",
        update: {"auth.is_member(group_id)", "auth.is_member(group_id)"}
      }
    },
    expenses: {
      [
        "SELECT",
        "INSERT",
        "UPDATE (description, amount_cents, date, category_id, paid_by, visibility, split, " <>
          "period_start, period_end, deleted_at, updated_at)"
      ],
      %{
        select:
          "(visibility = 'shared' AND auth.is_member(group_id)) " <>
            "OR (visibility = 'private' AND created_by = auth.uid())",
        insert:
          "auth.is_member(group_id) AND created_by = auth.uid() " <>
            "AND (visibility = 'shared' OR paid_by = auth.uid())",
        update:
          {"auth.is_member(group_id) AND (created_by = auth.uid() " <>
             "OR (visibility = 'shared' AND auth.is_admin(group_id)))",
           "auth.is_member(group_id) AND (visibility = 'shared' " <>
             "OR (created_by = auth.uid() AND paid_by = auth.uid()))"}
      }
    },
    expense_shares: {
      ["SELECT"],
      %{
        # Follows its expense: the subquery runs under the caller's own policies.
        select: "EXISTS (SELECT 1 FROM expenses e WHERE e.id = expense_id)",
        insert: nil,
        update: nil
      }
    },
    payments: {
      [
        "SELECT",
        "INSERT",
        "UPDATE (from_user_id, from_counterparty_id, to_user_id, to_counterparty_id, " <>
          "amount_cents, date, category_id, method, reference, status, deleted_at, updated_at)"
      ],
      %{
        select: "auth.is_member(group_id)",
        insert: "auth.is_member(group_id) AND recorded_by = auth.uid()",
        update:
          {"auth.is_member(group_id) AND (to_user_id = auth.uid() OR recorded_by = auth.uid())",
           "auth.is_member(group_id)"}
      }
    },
    audit_log: {
      ["SELECT"],
      %{
        select:
          "auth.is_member(group_id) " <>
            "AND (private_owner_id IS NULL OR private_owner_id = auth.uid())",
        insert: nil,
        update: nil
      }
    }
  ]

  @views ~w(balances category_balances)
  @internal_tables ~w(schema_migrations oban_jobs oban_peers)

  def up do
    execute "GRANT USAGE ON SCHEMA ledger TO tab_user"

    for table <- @internal_tables do
      execute "REVOKE ALL ON #{table} FROM tab_user"
    end

    for {table, {grants, policy}} <- @policies do
      execute "REVOKE ALL ON #{table} FROM tab_user"
      for grant <- grants, do: execute("GRANT #{grant} ON #{table} TO tab_user")

      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"

      execute "CREATE POLICY #{table}_select ON #{table} FOR SELECT TO tab_user USING (#{policy.select || "false"})"

      execute "CREATE POLICY #{table}_insert ON #{table} FOR INSERT TO tab_user WITH CHECK (#{policy.insert || "false"})"

      {using, check} = policy.update || {"false", "false"}

      execute "CREATE POLICY #{table}_update ON #{table} FOR UPDATE TO tab_user USING (#{using}) WITH CHECK (#{check})"

      # No role used by the app has DELETE; this policy refuses even if one did.
      execute "CREATE POLICY #{table}_delete ON #{table} FOR DELETE TO tab_user USING (false)"
    end

    for view <- @views do
      execute "REVOKE ALL ON #{view} FROM tab_user"
      execute "GRANT SELECT ON #{view} TO tab_user"
    end

    # Internal functions are for triggers and policies, not for people to call.
    execute "REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC"
    execute "GRANT EXECUTE ON FUNCTION ledger.valid_payment_methods(jsonb) TO tab_user"
    execute "GRANT EXECUTE ON FUNCTION ledger.stamp_actor() TO tab_user"
  end

  def down do
    for {table, _} <- @policies do
      for verb <- ~w(select insert update delete) do
        execute "DROP POLICY #{table}_#{verb} ON #{table}"
      end

      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end

    execute "REVOKE USAGE ON SCHEMA ledger FROM tab_user"
  end
end
