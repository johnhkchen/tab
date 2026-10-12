defmodule Tab.Repo.Migrations.RlsFoundation do
  @moduledoc """
  The plumbing every row-level security policy in Tab stands on (spec §6).

  * `tab_user` is the role every person-scoped query runs as. It can't log in,
    isn't a superuser, and can't bypass RLS, so policies always apply to it.
  * `auth.uid()` returns the id of the person the current transaction acts for,
    or NULL when nobody is set. Policies compare against it.
  * `tab_user` gets no DELETE on anything: the ledger keeps history (no hard deletes).

  Tables still need RLS enabled and an explicit policy per verb, written in their
  own migrations. Nothing here grants row access by itself.
  """
  use Ecto.Migration

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'tab_user') THEN
        CREATE ROLE tab_user NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT;
      END IF;
    END
    $$
    """

    # The connecting role must be able to SET ROLE to tab_user.
    execute "GRANT tab_user TO CURRENT_USER"

    execute "CREATE SCHEMA IF NOT EXISTS auth"

    execute """
    CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
      LANGUAGE sql STABLE
      AS $$ SELECT nullif(current_setting('app.user_id', true), '')::uuid $$
    """

    execute "GRANT USAGE ON SCHEMA auth TO tab_user"
    execute "GRANT EXECUTE ON FUNCTION auth.uid() TO tab_user"
    execute "GRANT USAGE ON SCHEMA public TO tab_user"

    execute """
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
      GRANT SELECT, INSERT, UPDATE ON TABLES TO tab_user
    """

    execute """
    ALTER DEFAULT PRIVILEGES IN SCHEMA public
      GRANT USAGE, SELECT ON SEQUENCES TO tab_user
    """
  end

  def down do
    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE USAGE, SELECT ON SEQUENCES FROM tab_user"

    execute "ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT, INSERT, UPDATE ON TABLES FROM tab_user"

    execute "REVOKE USAGE ON SCHEMA public FROM tab_user"
    execute "DROP FUNCTION IF EXISTS auth.uid()"
    execute "DROP SCHEMA IF EXISTS auth"
    # The role is cluster-wide and may be shared with other databases (dev + test),
    # so it is left in place.
  end
end
