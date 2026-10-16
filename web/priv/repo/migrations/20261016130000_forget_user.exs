defmodule Tab.Repo.Migrations.ForgetUser do
  @moduledoc """
  Deleting an account (docs/specification.md, "Phase 6", "Deleting an
  account"): `ledger.forget_user(uid)` removes a person and their private data
  in one transaction and keeps the shared ledger, so housemates' balances
  stay right. The one exception to "no hard deletes".

  Only the connection owner (`Tab.Accounts.delete_account/1`) can call it;
  `tab_user` can't. The audit log stays append-only except for this: it lets
  the function delete the entries about the person's own private expenses,
  and nothing else.
  """
  use Ecto.Migration

  @now "(now() AT TIME ZONE 'utc')"

  def up do
    # The audit log refuses every update and delete, except deleting entries
    # whose private owner is the person `forget_user` is forgetting.
    execute """
    CREATE OR REPLACE FUNCTION ledger.audit_is_append_only() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND OLD.private_owner_id IS NOT NULL
           AND OLD.private_owner_id::text = current_setting('ledger.forgetting', true) THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'the audit log is append-only' USING ERRCODE = '42501';
      END
      $$
    """

    execute """
    CREATE FUNCTION ledger.forget_user(uid uuid) RETURNS void
      LANGUAGE plpgsql SET search_path = pg_catalog, public
      AS $$
      DECLARE
        m record;
        heir uuid;
      BEGIN
        PERFORM set_config('ledger.forgetting', uid::text, true);

        -- Sign-in and connections.
        DELETE FROM users_tokens WHERE user_id = uid;
        DELETE FROM oauth_tokens WHERE connection_id IN (SELECT id FROM oauth_connections WHERE user_id = uid);
        DELETE FROM oauth_codes WHERE connection_id IN (SELECT id FROM oauth_connections WHERE user_id = uid);
        DELETE FROM oauth_connections WHERE user_id = uid;

        -- Bills: documents (including references kept on shared expenses),
        -- bills to check, received mail, forwarding addresses.
        DELETE FROM documents WHERE user_id = uid;
        DELETE FROM pending_items WHERE user_id = uid;
        DELETE FROM inbound_messages WHERE user_id = uid;
        DELETE FROM forwarding_addresses WHERE user_id = uid;

        -- Plans: what they asked for and what was read. The trial-once list
        -- keeps its hash of the address, with no link back to them.
        DELETE FROM extension_requests WHERE user_id = uid;
        DELETE FROM reads WHERE user_id = uid;
        DELETE FROM billing_accounts WHERE user_id = uid;

        -- Private expenses, their shares, and what the audit log says about them.
        DELETE FROM expense_shares WHERE expense_id IN
          (SELECT id FROM expenses WHERE visibility = 'private' AND created_by = uid);
        DELETE FROM audit_log WHERE private_owner_id = uid;
        DELETE FROM expenses WHERE visibility = 'private' AND created_by = uid;

        -- Statement links about their month stop working.
        UPDATE statement_links SET revoked_at = #{@now}
          WHERE user_id = uid AND revoked_at IS NULL;
        UPDATE recurring_templates SET default_payer = NULL WHERE default_payer = uid;

        -- Leave every group. A group keeps an admin: the longest-standing
        -- member takes over. A group with nobody left is archived.
        FOR m IN SELECT * FROM memberships WHERE user_id = uid AND left_at IS NULL LOOP
          IF m.role = 'admin' AND NOT EXISTS (
               SELECT 1 FROM memberships o WHERE o.group_id = m.group_id AND o.user_id <> uid
                 AND o.left_at IS NULL AND o.role = 'admin') THEN
            SELECT o.user_id INTO heir FROM memberships o
              WHERE o.group_id = m.group_id AND o.user_id <> uid AND o.left_at IS NULL
              ORDER BY o.joined_at, o.user_id LIMIT 1;
            IF heir IS NOT NULL THEN
              UPDATE memberships SET role = 'admin', updated_at = #{@now}
                WHERE group_id = m.group_id AND user_id = heir AND left_at IS NULL;
            END IF;
          END IF;

          UPDATE memberships SET left_at = #{@now}, updated_at = #{@now}
            WHERE group_id = m.group_id AND user_id = uid AND left_at IS NULL;

          IF NOT EXISTS (SELECT 1 FROM memberships o WHERE o.group_id = m.group_id AND o.left_at IS NULL) THEN
            UPDATE groups SET deleted_at = #{@now}, updated_at = #{@now}
              WHERE id = m.group_id AND deleted_at IS NULL;
          END IF;
        END LOOP;

        -- What stays: a name for the shared ledger, and an address nobody can use.
        UPDATE profiles SET display_name = 'Former member', payment_methods = '[]', updated_at = #{@now}
          WHERE user_id = uid;
        UPDATE users SET email = 'deleted-' || uid || '@deleted.invalid', hashed_password = NULL,
          confirmed_at = NULL
          WHERE id = uid;
      END
      $$
    """

    execute "REVOKE EXECUTE ON FUNCTION ledger.forget_user(uuid) FROM PUBLIC"
    execute "REVOKE EXECUTE ON FUNCTION ledger.forget_user(uuid) FROM tab_user"
  end

  def down do
    execute "DROP FUNCTION ledger.forget_user(uuid)"

    execute """
    CREATE OR REPLACE FUNCTION ledger.audit_is_append_only() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'the audit log is append-only' USING ERRCODE = '42501';
      END
      $$
    """
  end
end
