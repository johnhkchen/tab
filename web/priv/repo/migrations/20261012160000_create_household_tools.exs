defmodule Tab.Repo.Migrations.CreateHouseholdTools do
  @moduledoc """
  Phase 3 (docs/specification.md, "Phase 3"): recurring templates, temporary
  splits (time-bound overrides), and statement links, with their triggers,
  `read_statement`, grants, and one policy per verb.

  Same conventions as the phase 1 migrations: `created_by` comes from
  `auth.uid()`, every table is audited, `tab_user` never gets DELETE, and
  internal functions live in the `ledger` schema with a pinned `search_path`.
  """
  use Ecto.Migration

  @now "(now() AT TIME ZONE 'utc')"
  @stamps """
    inserted_at timestamp(0) NOT NULL DEFAULT #{@now},
    updated_at timestamp(0) NOT NULL DEFAULT #{@now}
  """

  # table => {grants, %{select:, insert:, update: {using, check}}}; nil refuses.
  @policies [
    recurring_templates: {
      [
        "SELECT",
        "INSERT",
        "UPDATE (name, category_id, cadence, cadence_days, stability, default_payer, " <>
          "default_split, autopay_day, deleted_at, updated_at)"
      ],
      %{
        select: "auth.is_member(group_id)",
        insert: "auth.can_write(group_id) AND created_by = auth.uid()",
        update: {"auth.can_write(group_id)", "auth.can_write(group_id)"}
      }
    },
    split_overrides: {
      [
        "SELECT",
        "INSERT",
        "UPDATE (category_id, effective_from, effective_until, split, note, deleted_at, updated_at)"
      ],
      %{
        select: "auth.is_member(group_id)",
        insert: "auth.can_admin(group_id) AND created_by = auth.uid()",
        update: {"auth.can_admin(group_id)", "auth.can_admin(group_id)"}
      }
    },
    statement_links: {
      ["SELECT", "INSERT", "UPDATE (revoked_at, updated_at)"],
      %{
        select: "auth.is_member(group_id)",
        insert: "auth.can_write(group_id) AND created_by = auth.uid()",
        update: {"auth.can_write(group_id)", "auth.can_write(group_id)"}
      }
    }
  ]

  def up do
    execute "SET LOCAL check_function_bodies = off"

    # -- Shared checks --------------------------------------------------------

    # Everyone named in a split is, or was, in the group.
    execute """
    CREATE FUNCTION ledger.split_parties_ok(gid uuid, split jsonb) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(split->'entries') e
           WHERE num_nonnulls(e->>'user_id', e->>'counterparty_id') <> 1
              OR (e ? 'user_id' AND NOT ledger.is_member_user(gid, (e->>'user_id')::uuid, true))
              OR (e ? 'counterparty_id' AND NOT EXISTS (
                    SELECT 1 FROM counterparties c
                     WHERE c.id = (e->>'counterparty_id')::uuid AND c.group_id = gid)))
      $$
    """

    # -- Tables --------------------------------------------------------------

    execute """
    CREATE TABLE recurring_templates (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
      category_id uuid,
      cadence text NOT NULL DEFAULT 'monthly'
        CHECK (cadence IN ('monthly', 'bimonthly', 'quarterly', 'custom_n_days', 'irregular')),
      cadence_days integer CHECK (cadence_days BETWEEN 1 AND 366),
      stability text NOT NULL DEFAULT 'variable' CHECK (stability IN ('fixed', 'variable')),
      default_payer uuid REFERENCES users (id),
      default_split jsonb CHECK (
        jsonb_typeof(default_split) = 'object'
        AND default_split->>'type' IN ('equal', 'exact', 'percentage', 'shares')
        AND jsonb_typeof(default_split->'entries') = 'array'
        AND jsonb_array_length(default_split->'entries') > 0),
      autopay_day integer CHECK (autopay_day BETWEEN 1 AND 31),
      last_amount_cents bigint,
      last_logged_on date,
      created_by uuid NOT NULL REFERENCES users (id),
      deleted_at timestamp(0),
      #{@stamps},
      UNIQUE (id, group_id),
      CHECK ((cadence = 'custom_n_days') = (cadence_days IS NOT NULL)),
      FOREIGN KEY (category_id, group_id) REFERENCES categories (id, group_id)
    )
    """

    execute """
    CREATE UNIQUE INDEX recurring_templates_unique_name
      ON recurring_templates (group_id, lower(name)) WHERE deleted_at IS NULL
    """

    execute "ALTER TABLE expenses ADD COLUMN template_id uuid"

    execute """
    ALTER TABLE expenses
      ADD CONSTRAINT expenses_template_fkey FOREIGN KEY (template_id, group_id)
        REFERENCES recurring_templates (id, group_id),
      ADD CONSTRAINT expenses_template_shared CHECK (template_id IS NULL OR visibility = 'shared')
    """

    execute "CREATE INDEX expenses_template ON expenses (template_id) WHERE template_id IS NOT NULL"

    execute """
    CREATE TABLE split_overrides (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      category_id uuid,
      effective_from date NOT NULL,
      effective_until date CHECK (effective_until >= effective_from),
      split jsonb NOT NULL CHECK (
        jsonb_typeof(split) = 'object'
        AND split->>'type' IN ('equal', 'percentage', 'shares')
        AND jsonb_typeof(split->'entries') = 'array'
        AND jsonb_array_length(split->'entries') > 0),
      note text CHECK (char_length(note) <= 200),
      created_by uuid NOT NULL REFERENCES users (id),
      deleted_at timestamp(0),
      #{@stamps},
      FOREIGN KEY (category_id, group_id) REFERENCES categories (id, group_id)
    )
    """

    execute "CREATE INDEX split_overrides_group ON split_overrides (group_id, effective_from)"

    execute """
    CREATE TABLE statement_links (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
      user_id uuid REFERENCES users (id),
      counterparty_id uuid,
      period_start date NOT NULL CHECK (period_start = date_trunc('month', period_start)::date),
      period_end date NOT NULL,
      expires_at timestamp(0) NOT NULL DEFAULT (#{@now} + interval '30 days'),
      revoked_at timestamp(0),
      created_by uuid NOT NULL REFERENCES users (id),
      #{@stamps},
      CHECK (num_nonnulls(user_id, counterparty_id) = 1),
      CHECK (period_end = (period_start + interval '1 month' - interval '1 day')::date),
      FOREIGN KEY (counterparty_id, group_id) REFERENCES counterparties (id, group_id)
    )
    """

    execute "CREATE INDEX statement_links_group ON statement_links (group_id)"

    for table <- ~w(recurring_templates split_overrides statement_links) do
      execute """
      CREATE TRIGGER #{table}_stamp_created_by BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION ledger.stamp_actor('created_by')
      """

      execute """
      CREATE TRIGGER #{table}_audit AFTER INSERT OR UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION ledger.audit()
      """
    end

    # -- Templates: people set the plan; the database keeps last_* ------------

    execute """
    CREATE FUNCTION ledger.guard_template() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF TG_OP = 'INSERT' AND auth.uid() IS NOT NULL THEN
          NEW.last_amount_cents := NULL;
          NEW.last_logged_on := NULL;
        END IF;
        IF NEW.default_payer IS NOT NULL
           AND NEW.default_payer IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.default_payer END)
           AND NOT ledger.is_member_user(NEW.group_id, NEW.default_payer) THEN
          RAISE EXCEPTION 'whoever usually pays must be in the group' USING ERRCODE = '23514';
        END IF;
        IF NEW.default_split IS NOT NULL
           AND NEW.default_split IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.default_split END)
           AND NOT ledger.split_parties_ok(NEW.group_id, NEW.default_split) THEN
          RAISE EXCEPTION 'everyone in a split must be in the group' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER recurring_templates_guard BEFORE INSERT OR UPDATE ON recurring_templates
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_template()
    """

    # A template's last amount and date follow its newest live expense, through
    # adds, edits, and deletes. Runs as the owner: people can't write these columns.
    execute """
    CREATE FUNCTION ledger.sync_template() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        tid uuid;
      BEGIN
        FOR tid IN
          SELECT DISTINCT t FROM unnest(ARRAY[NEW.template_id,
            CASE WHEN TG_OP = 'UPDATE' THEN OLD.template_id END]) AS t
           WHERE t IS NOT NULL
        LOOP
          WITH newest AS (
            SELECT e.amount_cents, e.date FROM expenses e
             WHERE e.template_id = tid AND e.deleted_at IS NULL
             ORDER BY e.date DESC, e.inserted_at DESC, e.id DESC
             LIMIT 1
          )
          UPDATE recurring_templates rt
             SET last_amount_cents = (SELECT amount_cents FROM newest),
                 last_logged_on = (SELECT date FROM newest)
           WHERE rt.id = tid
             AND (rt.last_amount_cents, rt.last_logged_on) IS DISTINCT FROM
                 ((SELECT amount_cents FROM newest), (SELECT date FROM newest));
        END LOOP;
        RETURN NULL;
      END
      $$
    """

    execute """
    CREATE TRIGGER expenses_sync_template
      AFTER INSERT OR UPDATE OF template_id, amount_cents, date, deleted_at ON expenses
      FOR EACH ROW EXECUTE FUNCTION ledger.sync_template()
    """

    # -- Temporary splits never overlap on the same bills ------------------------
    # No category means every category, so it collides with all of them. The
    # advisory lock keeps two admins from saving overlapping ones at once.

    execute """
    CREATE FUNCTION ledger.guard_override() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF NEW.split IS DISTINCT FROM (CASE WHEN TG_OP = 'UPDATE' THEN OLD.split END)
           AND NOT ledger.split_parties_ok(NEW.group_id, NEW.split) THEN
          RAISE EXCEPTION 'everyone in a split must be in the group' USING ERRCODE = '23514';
        END IF;
        IF NEW.deleted_at IS NOT NULL THEN
          RETURN NEW;
        END IF;
        PERFORM pg_advisory_xact_lock(hashtextextended('split_overrides:' || NEW.group_id::text, 0));
        IF EXISTS (
          SELECT 1 FROM split_overrides o
           WHERE o.group_id = NEW.group_id AND o.id <> NEW.id AND o.deleted_at IS NULL
             AND (o.category_id IS NULL OR NEW.category_id IS NULL OR o.category_id = NEW.category_id)
             AND daterange(o.effective_from, o.effective_until, '[]')
                 && daterange(NEW.effective_from, NEW.effective_until, '[]')) THEN
          RAISE EXCEPTION 'this overlaps another temporary split on the same bills'
            USING ERRCODE = 'P0001', HINT = 'override_overlap';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER split_overrides_guard BEFORE INSERT OR UPDATE ON split_overrides
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_override()
    """

    # -- Statement links: 30 days at most, and revoked stays revoked -------------

    execute """
    CREATE FUNCTION ledger.guard_statement_link() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          IF NEW.user_id IS NOT NULL AND NOT ledger.is_member_user(NEW.group_id, NEW.user_id, true) THEN
            RAISE EXCEPTION 'a statement is for someone in the group' USING ERRCODE = '23514';
          END IF;
          IF auth.uid() IS NOT NULL THEN
            NEW.revoked_at := NULL;
            NEW.expires_at := least(NEW.expires_at, #{@now} + interval '30 days');
          END IF;
        ELSIF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
          RAISE EXCEPTION 'a statement link stays revoked' USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER statement_links_guard BEFORE INSERT OR UPDATE ON statement_links
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_statement_link()
    """

    execute """
    CREATE FUNCTION ledger.party_name(kind text, pid uuid) RETURNS text
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT CASE kind
                 WHEN 'user' THEN (SELECT display_name FROM profiles WHERE user_id = pid)
                 ELSE (SELECT name FROM counterparties WHERE id = pid)
               END
      $$
    """

    # One person's month, for a link that needs no sign-in. Runs as the owner,
    # so it decides on its own what to show: that person's shares and payments
    # in that month, never private expenses, and where they stand today. Every
    # bad token looks the same.
    execute """
    CREATE FUNCTION public.read_statement(token text) RETURNS jsonb
      LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        l statement_links;
        kind text;
        pid uuid;
      BEGIN
        SELECT * INTO l FROM statement_links
         WHERE token_hash = sha256(convert_to(coalesce(token, ''), 'UTF8'));

        IF NOT FOUND OR l.revoked_at IS NOT NULL OR l.expires_at <= #{@now} THEN
          RAISE EXCEPTION 'this statement link is not valid'
            USING ERRCODE = 'P0001', HINT = 'invalid_statement';
        END IF;

        kind := CASE WHEN l.user_id IS NOT NULL THEN 'user' ELSE 'counterparty' END;
        pid := coalesce(l.user_id, l.counterparty_id);

        RETURN jsonb_build_object(
          'group', (SELECT name FROM groups WHERE id = l.group_id),
          'recipient', ledger.party_name(kind, pid),
          'period_start', l.period_start,
          'period_end', l.period_end,
          'expires_at', l.expires_at,
          'expenses', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                     'date', e.date,
                     'description', e.description,
                     'category', c.name,
                     'amount_cents', e.amount_cents,
                     'share_cents', coalesce(s.amount_cents, 0),
                     'paid_by', ledger.party_name('user', e.paid_by),
                     'paid_by_recipient', kind = 'user' AND e.paid_by = pid)
                   ORDER BY e.date, e.inserted_at, e.id)
              FROM expenses e
              LEFT JOIN expense_shares s ON s.expense_id = e.id
                   AND ((kind = 'user' AND s.user_id = pid)
                     OR (kind = 'counterparty' AND s.counterparty_id = pid))
              LEFT JOIN categories c ON c.id = e.category_id
             WHERE e.group_id = l.group_id
               AND e.visibility = 'shared'
               AND e.deleted_at IS NULL
               AND e.date BETWEEN l.period_start AND l.period_end
               AND (s.id IS NOT NULL OR (kind = 'user' AND e.paid_by = pid))), '[]'),
          'payments', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                     'date', p.date,
                     'amount_cents', p.amount_cents,
                     'direction', CASE WHEN coalesce(p.from_user_id, p.from_counterparty_id) = pid
                                       THEN 'paid' ELSE 'received' END,
                     'other', CASE WHEN coalesce(p.from_user_id, p.from_counterparty_id) = pid
                                   THEN ledger.party_name(
                                          CASE WHEN p.to_user_id IS NOT NULL THEN 'user' ELSE 'counterparty' END,
                                          coalesce(p.to_user_id, p.to_counterparty_id))
                                   ELSE ledger.party_name(
                                          CASE WHEN p.from_user_id IS NOT NULL THEN 'user' ELSE 'counterparty' END,
                                          coalesce(p.from_user_id, p.from_counterparty_id)) END,
                     'method', p.method,
                     'status', p.status)
                   ORDER BY p.date, p.inserted_at, p.id)
              FROM payments p
             WHERE p.group_id = l.group_id
               AND p.deleted_at IS NULL
               AND p.status <> 'declined'
               AND p.date BETWEEN l.period_start AND l.period_end
               AND pid IN (coalesce(p.from_user_id, p.from_counterparty_id),
                           coalesce(p.to_user_id, p.to_counterparty_id))), '[]'),
          'standing', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                     'owes', b.debtor_id = pid AND b.debtor_kind = kind,
                     'other', CASE WHEN b.debtor_id = pid AND b.debtor_kind = kind
                                   THEN ledger.party_name(b.creditor_kind, b.creditor_id)
                                   ELSE ledger.party_name(b.debtor_kind, b.debtor_id) END,
                     'amount_cents', b.amount_cents)
                   ORDER BY b.amount_cents DESC)
              FROM balances b
             WHERE b.group_id = l.group_id
               AND ((b.debtor_kind = kind AND b.debtor_id = pid)
                 OR (b.creditor_kind = kind AND b.creditor_id = pid))), '[]'));
      END
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

    execute "GRANT UPDATE (template_id) ON expenses TO tab_user"

    execute "REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ledger FROM PUBLIC"
    execute "GRANT EXECUTE ON FUNCTION ledger.valid_payment_methods(jsonb) TO tab_user"
    execute "GRANT EXECUTE ON FUNCTION ledger.stamp_actor() TO tab_user"
    execute "REVOKE EXECUTE ON FUNCTION public.read_statement(text) FROM PUBLIC"
    execute "GRANT EXECUTE ON FUNCTION public.read_statement(text) TO tab_user"
  end

  def down do
    execute "DROP FUNCTION public.read_statement(text)"
    execute "DROP TRIGGER expenses_sync_template ON expenses"
    execute "REVOKE UPDATE (template_id) ON expenses FROM tab_user"

    execute """
    ALTER TABLE expenses
      DROP CONSTRAINT expenses_template_shared,
      DROP CONSTRAINT expenses_template_fkey,
      DROP COLUMN template_id
    """

    for table <- ~w(statement_links split_overrides recurring_templates) do
      execute "DROP TABLE #{table}"
    end

    for fun <- [
          "party_name(text, uuid)",
          "guard_statement_link()",
          "guard_override()",
          "sync_template()",
          "guard_template()",
          "split_parties_ok(uuid, jsonb)"
        ] do
      execute "DROP FUNCTION ledger.#{fun}"
    end
  end
end
