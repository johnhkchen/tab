defmodule Tab.Repo.Migrations.CreateInbox do
  @moduledoc """
  Phase 4 (docs/specification.md, "Phase 4"): forwarding addresses (one per
  person per group), received
  mail, documents, and pending items, with grants and one policy per verb.

  These tables belong to one person, not a group, so they stay out of the
  group audit log. The expense a pending item becomes is audited as usual.
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
    forwarding_addresses: {
      ["SELECT", "INSERT", "UPDATE (revoked_at, updated_at)"],
      %{
        select: @mine,
        insert: "#{@mine} AND auth.is_member(group_id)",
        update: {@mine, @mine}
      }
    },
    inbound_messages: {
      ["SELECT"],
      %{select: @mine, insert: nil, update: nil}
    },
    documents: {
      ["SELECT", "INSERT", "UPDATE (expense_id, content, purged_at, updated_at)"],
      %{
        # A kept document is as visible as its expense: the subquery runs
        # under the reader's own policies on expenses.
        select:
          "#{@mine} OR (expense_id IS NOT NULL AND EXISTS " <>
            "(SELECT 1 FROM expenses e WHERE e.id = documents.expense_id))",
        insert: @mine,
        update: {@mine, @mine}
      }
    },
    pending_items: {
      [
        "SELECT",
        "INSERT",
        "UPDATE (status, doc_type, proposal, due_on, template_id, group_id, expense_id, " <>
          "duplicate_of, note, read_at, updated_at)"
      ],
      %{
        select: @mine,
        insert: "#{@mine} AND ledger.pending_refs_ok(pending_items)",
        update: {@mine, "#{@mine} AND ledger.pending_refs_ok(pending_items)"}
      }
    }
  ]

  def up do
    execute "SET LOCAL check_function_bodies = off"

    execute """
    CREATE TABLE forwarding_addresses (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id),
      group_id uuid NOT NULL REFERENCES groups (id),
      -- The group's name for people to read, then a random tag: the secret.
      local_part text NOT NULL UNIQUE
        CHECK (local_part ~ '^([a-z0-9]+-)+[a-z2-7]{10}$' AND char_length(local_part) <= 64),
      revoked_at timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE UNIQUE INDEX forwarding_addresses_one_live
      ON forwarding_addresses (user_id, group_id) WHERE revoked_at IS NULL
    """

    execute """
    CREATE TABLE inbound_messages (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      provider text NOT NULL CHECK (provider IN ('resend')),
      provider_id text NOT NULL CHECK (char_length(provider_id) BETWEEN 1 AND 200),
      user_id uuid REFERENCES users (id),
      status text NOT NULL DEFAULT 'fetching'
        CHECK (status IN ('fetching', 'stored', 'unmatched', 'failed')),
      kind text NOT NULL DEFAULT 'bill' CHECK (kind IN ('bill', 'gmail_check')),
      detail text CHECK (char_length(detail) <= 500),
      from_address text CHECK (char_length(from_address) <= 320),
      subject text CHECK (char_length(subject) <= 500),
      received_at timestamp(0) NOT NULL DEFAULT #{@now},
      #{@stamps},
      UNIQUE (provider, provider_id)
    )
    """

    execute "CREATE INDEX inbound_messages_user ON inbound_messages (user_id, received_at)"

    execute """
    CREATE TABLE documents (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id),
      kind text NOT NULL CHECK (kind IN ('photo', 'pdf', 'email')),
      content_type text NOT NULL CHECK (char_length(content_type) <= 100),
      filename text CHECK (char_length(filename) <= 255),
      byte_size integer NOT NULL CHECK (byte_size > 0 AND byte_size <= 10485760),
      sha256 bytea NOT NULL CHECK (octet_length(sha256) = 32),
      content bytea,
      expense_id uuid REFERENCES expenses (id),
      purged_at timestamp(0),
      #{@stamps},
      CHECK ((content IS NULL) = (purged_at IS NOT NULL)),
      CHECK (content IS NULL OR octet_length(content) = byte_size),
      CHECK (kind <> 'photo' OR byte_size <= 2097152)
    )
    """

    execute "CREATE INDEX documents_user_sha ON documents (user_id, sha256)"

    execute "CREATE INDEX documents_expense ON documents (expense_id) WHERE expense_id IS NOT NULL"

    execute """
    CREATE TABLE pending_items (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id),
      document_id uuid NOT NULL REFERENCES documents (id),
      source text NOT NULL CHECK (source IN ('upload', 'email')),
      status text NOT NULL DEFAULT 'reading'
        CHECK (status IN ('reading', 'ready', 'unreadable', 'waiting', 'confirmed', 'dismissed')),
      doc_type text
        CHECK (doc_type IN ('utility', 'receipt', 'subscription', 'rent', 'travel', 'phone', 'other')),
      proposal jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(proposal) = 'object'),
      due_on date,
      template_id uuid REFERENCES recurring_templates (id),
      group_id uuid REFERENCES groups (id),
      expense_id uuid REFERENCES expenses (id),
      duplicate_of uuid REFERENCES expenses (id),
      note text CHECK (char_length(note) <= 500),
      read_at timestamp(0),
      #{@stamps},
      CHECK ((status = 'confirmed') = (expense_id IS NOT NULL))
    )
    """

    execute "CREATE INDEX pending_items_user ON pending_items (user_id, status, inserted_at)"

    execute "ALTER TABLE recurring_templates ADD COLUMN sender text CHECK (sender = lower(sender) AND char_length(sender) BETWEEN 3 AND 320)"

    execute """
    ALTER TABLE profiles ADD COLUMN digest_days integer[] NOT NULL DEFAULT '{10,25}'
      CHECK (cardinality(digest_days) <= 4 AND digest_days <@ ARRAY[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28])
    """

    for table <- ~w(forwarding_addresses documents pending_items) do
      execute """
      CREATE TRIGGER #{table}_stamp_user BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION ledger.stamp_actor('user_id')
      """
    end

    # -- Guards ---------------------------------------------------------------

    # A revoked address stays revoked.
    execute """
    CREATE FUNCTION ledger.guard_forwarding_address() RETURNS trigger
      LANGUAGE plpgsql SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
          RAISE EXCEPTION 'a revoked address stays revoked' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER forwarding_addresses_guard BEFORE UPDATE ON forwarding_addresses
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_forwarding_address()
    """

    # Content only ever goes away, and a document joins only an expense its
    # owner can see. SECURITY INVOKER on purpose: the expense lookup runs under
    # the caller's own policies.
    execute """
    CREATE FUNCTION ledger.guard_document() RETURNS trigger
      LANGUAGE plpgsql SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF NEW.content IS DISTINCT FROM OLD.content THEN
          IF NEW.content IS NOT NULL THEN
            RAISE EXCEPTION 'a document''s content can only be removed' USING ERRCODE = '23514';
          END IF;
          NEW.purged_at := #{@now};
        ELSIF NEW.purged_at IS DISTINCT FROM OLD.purged_at THEN
          RAISE EXCEPTION 'purged_at follows the content' USING ERRCODE = '23514';
        END IF;
        IF NEW.expense_id IS DISTINCT FROM OLD.expense_id THEN
          IF OLD.expense_id IS NOT NULL THEN
            RAISE EXCEPTION 'a kept document stays with its expense' USING ERRCODE = '23514';
          END IF;
          IF NOT EXISTS (SELECT 1 FROM expenses e WHERE e.id = NEW.expense_id AND e.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'that expense isn''t one you can see' USING ERRCODE = '23514';
          END IF;
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER documents_guard BEFORE UPDATE ON documents
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_document()
    """

    # Everything a pending item points at must be the owner's to see: their
    # document, and a group, template, and expenses visible to them. Runs as
    # the caller (SECURITY INVOKER), so each lookup obeys their policies.
    execute """
    CREATE FUNCTION ledger.pending_refs_ok(p pending_items) RETURNS boolean
      LANGUAGE sql STABLE SET search_path = pg_catalog, public
      AS $$
        SELECT EXISTS (SELECT 1 FROM documents d WHERE d.id = p.document_id AND d.user_id = p.user_id)
          AND (p.group_id IS NULL OR auth.is_member(p.group_id))
          AND (p.template_id IS NULL OR EXISTS (
                SELECT 1 FROM recurring_templates t WHERE t.id = p.template_id))
          AND (p.expense_id IS NULL OR EXISTS (SELECT 1 FROM expenses e WHERE e.id = p.expense_id))
          AND (p.duplicate_of IS NULL OR EXISTS (SELECT 1 FROM expenses e WHERE e.id = p.duplicate_of))
      $$
    """

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

    execute "GRANT UPDATE (sender) ON recurring_templates TO tab_user"
    execute "GRANT UPDATE (digest_days) ON profiles TO tab_user"

    execute "REVOKE EXECUTE ON FUNCTION ledger.pending_refs_ok(pending_items) FROM PUBLIC"
    execute "GRANT EXECUTE ON FUNCTION ledger.pending_refs_ok(pending_items) TO tab_user"
  end

  def down do
    execute "REVOKE UPDATE (digest_days) ON profiles FROM tab_user"
    execute "REVOKE UPDATE (sender) ON recurring_templates FROM tab_user"
    execute "ALTER TABLE profiles DROP COLUMN digest_days"
    execute "ALTER TABLE recurring_templates DROP COLUMN sender"

    # CASCADE takes the pending_items policies that call it.
    execute "DROP FUNCTION ledger.pending_refs_ok(pending_items) CASCADE"

    for table <- ~w(pending_items documents inbound_messages forwarding_addresses) do
      execute "DROP TABLE #{table}"
    end

    for fun <- ["guard_document()", "guard_forwarding_address()"] do
      execute "DROP FUNCTION ledger.#{fun}"
    end
  end
end
