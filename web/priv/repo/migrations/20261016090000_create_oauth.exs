defmodule Tab.Repo.Migrations.CreateOauth do
  @moduledoc """
  Phase 5 (docs/specification.md, "Phase 5"): Tab's own OAuth server for the
  MCP server. Clients, connections (one per approval), codes, and tokens,
  with grants and one policy per verb, plus `via` on expenses and payments.

  Clients, codes, and tokens are read before anyone is known, so only
  `Tab.OAuth`, as the connection owner, touches them; `tab_user` gets nothing.
  A person sees and revokes their own connections.
  """
  use Ecto.Migration

  @now "(now() AT TIME ZONE 'utc')"
  @stamps """
    inserted_at timestamp(0) NOT NULL DEFAULT #{@now},
    updated_at timestamp(0) NOT NULL DEFAULT #{@now}
  """

  @mine "user_id = auth.uid()"

  # table => {grants, %{select:, insert:, update: {using, check}}}; nil refuses.
  @policies [
    oauth_clients: {[], %{select: nil, insert: nil, update: nil}},
    oauth_connections: {
      ["SELECT", "INSERT", "UPDATE (revoked_at, updated_at)"],
      %{select: @mine, insert: @mine, update: {@mine, @mine}}
    },
    oauth_codes: {[], %{select: nil, insert: nil, update: nil}},
    oauth_tokens: {[], %{select: nil, insert: nil, update: nil}}
  ]

  def up do
    execute """
    CREATE TABLE oauth_clients (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      -- The metadata document's URL (CIMD), or a random id (DCR).
      client_id text NOT NULL UNIQUE CHECK (char_length(client_id) BETWEEN 1 AND 500),
      kind text NOT NULL CHECK (kind IN ('cimd', 'dcr')),
      name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
      redirect_uris text[] NOT NULL
        CHECK (cardinality(redirect_uris) BETWEEN 1 AND 20),
      -- CIMD only: when the document was fetched and how long it stays fresh.
      fetched_at timestamp(0),
      fresh_until timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE TABLE oauth_connections (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id),
      client_id uuid NOT NULL REFERENCES oauth_clients (id),
      scopes text[] NOT NULL
        CHECK (cardinality(scopes) >= 1 AND scopes <@ ARRAY['tab:read', 'tab:write']),
      last_used_at timestamp(0),
      revoked_at timestamp(0),
      #{@stamps}
    )
    """

    execute "CREATE INDEX oauth_connections_user ON oauth_connections (user_id) WHERE revoked_at IS NULL"

    execute """
    CREATE TABLE oauth_codes (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      connection_id uuid NOT NULL REFERENCES oauth_connections (id),
      code_hash bytea NOT NULL UNIQUE CHECK (octet_length(code_hash) = 32),
      redirect_uri text NOT NULL CHECK (char_length(redirect_uri) <= 2000),
      code_challenge text NOT NULL CHECK (code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
      resource text NOT NULL CHECK (char_length(resource) <= 500),
      expires_at timestamp(0) NOT NULL,
      used_at timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE TABLE oauth_tokens (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      connection_id uuid NOT NULL REFERENCES oauth_connections (id),
      code_id uuid REFERENCES oauth_codes (id),
      kind text NOT NULL CHECK (kind IN ('access', 'refresh')),
      token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
      resource text NOT NULL CHECK (char_length(resource) <= 500),
      expires_at timestamp(0) NOT NULL,
      used_at timestamp(0),
      revoked_at timestamp(0),
      #{@stamps}
    )
    """

    execute "CREATE INDEX oauth_tokens_connection ON oauth_tokens (connection_id)"

    execute """
    CREATE TRIGGER oauth_connections_stamp_user BEFORE INSERT ON oauth_connections
      FOR EACH ROW EXECUTE FUNCTION ledger.stamp_actor('user_id')
    """

    # A revoked connection stays revoked.
    execute """
    CREATE FUNCTION ledger.guard_oauth_connection() RETURNS trigger
      LANGUAGE plpgsql SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
          RAISE EXCEPTION 'a revoked connection stays revoked' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER oauth_connections_guard BEFORE UPDATE ON oauth_connections
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_oauth_connection()
    """

    # -- Where a write came from ----------------------------------------------

    # `via` comes from the session (`Tab.Repo.as_user/3`), never the client.
    execute """
    CREATE FUNCTION ledger.stamp_via() RETURNS trigger
      LANGUAGE plpgsql SET search_path = pg_catalog, public
      AS $$
      BEGIN
        NEW.via := CASE current_setting('app.via', true) WHEN 'claude' THEN 'claude' ELSE 'web' END;
        RETURN NEW;
      END
      $$
    """

    for table <- ~w(expenses payments) do
      execute """
      ALTER TABLE #{table} ADD COLUMN via text NOT NULL DEFAULT 'web'
        CHECK (via IN ('web', 'claude'))
      """

      execute """
      CREATE TRIGGER #{table}_stamp_via BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION ledger.stamp_via()
      """
    end

    # -- Grants and policies ---------------------------------------------------

    for {table, {grants, policy}} <- @policies do
      execute "REVOKE ALL ON #{table} FROM tab_user"
      for grant <- grants, do: execute("GRANT #{grant} ON #{table} TO tab_user")
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"

      execute "CREATE POLICY #{table}_select ON #{table} FOR SELECT TO tab_user USING (#{policy.select || "false"})"

      execute "CREATE POLICY #{table}_insert ON #{table} FOR INSERT TO tab_user WITH CHECK (#{policy.insert || "false"})"

      {using, check} = policy.update || {"false", "false"}

      execute "CREATE POLICY #{table}_update ON #{table} FOR UPDATE TO tab_user USING (#{using}) WITH CHECK (#{check})"

      execute "CREATE POLICY #{table}_delete ON #{table} FOR DELETE TO tab_user USING (false)"
    end

    # A person's own connection list names the client, so they can read the
    # names of clients they've connected, and nothing else about them.
    execute "GRANT SELECT (id, name, client_id, kind) ON oauth_clients TO tab_user"

    execute """
    ALTER POLICY oauth_clients_select ON oauth_clients USING (
      EXISTS (SELECT 1 FROM oauth_connections c WHERE c.client_id = oauth_clients.id)
    )
    """
  end

  def down do
    for table <- ~w(expenses payments) do
      execute "DROP TRIGGER #{table}_stamp_via ON #{table}"
      execute "ALTER TABLE #{table} DROP COLUMN via"
    end

    execute "DROP FUNCTION ledger.stamp_via()"

    for table <- ~w(oauth_tokens oauth_codes oauth_connections oauth_clients) do
      execute "DROP TABLE #{table} CASCADE"
    end

    execute "DROP FUNCTION ledger.guard_oauth_connection()"
  end
end
