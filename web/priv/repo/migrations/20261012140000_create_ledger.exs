defmodule Tab.Repo.Migrations.CreateLedger do
  @moduledoc """
  The phase 1 ledger (docs/specification.md, "Phase 1"): tables, the triggers
  that stamp and guard them, the audit log, the balance views, and the two
  functions people call directly (`accept_invite`, `set_expense_shares`).

  Row-level security policies and grants live in the next migration,
  `*_ledger_policies.exs`, so each file reads as one concern.

  Conventions:

  * Ids are UUIDs. Ecto generates them client-side, so inserts don't need
    `RETURNING` (which would check the select policy before the creator's
    membership exists).
  * Columns the client must not choose (`created_by`, `recorded_by`, payment
    `status`) are set by `BEFORE INSERT` triggers from `auth.uid()`. When no
    person is set (the connection owner, in `Tab.Accounts` and seeds), the
    supplied value is kept.
  * Internal functions live in the `ledger` schema. `SECURITY DEFINER`
    functions pin `search_path`.
  """
  use Ecto.Migration

  @now "(now() AT TIME ZONE 'utc')"
  @stamps """
    inserted_at timestamp(0) NOT NULL DEFAULT #{@now},
    updated_at timestamp(0) NOT NULL DEFAULT #{@now}
  """
  @payment_methods "('venmo', 'zelle', 'cashapp', 'paypal', 'cash', 'check', 'other')"

  # Money moving between two parties, one row per expense share or payment.
  # Positive amounts mean the debtor owes the creditor more.
  @flows """
    SELECT s.group_id, e.category_id,
           CASE WHEN s.user_id IS NOT NULL THEN 'user' ELSE 'counterparty' END AS debtor_kind,
           coalesce(s.user_id, s.counterparty_id) AS debtor_id,
           'user'::text AS creditor_kind,
           e.paid_by AS creditor_id,
           s.amount_cents
      FROM expense_shares s
      JOIN expenses e ON e.id = s.expense_id
     WHERE e.deleted_at IS NULL
       AND s.user_id IS DISTINCT FROM e.paid_by
    UNION ALL
    SELECT p.group_id, p.category_id,
           CASE WHEN p.from_user_id IS NOT NULL THEN 'user' ELSE 'counterparty' END,
           coalesce(p.from_user_id, p.from_counterparty_id),
           CASE WHEN p.to_user_id IS NOT NULL THEN 'user' ELSE 'counterparty' END,
           coalesce(p.to_user_id, p.to_counterparty_id),
           -p.amount_cents
      FROM payments p
     WHERE p.deleted_at IS NULL
       AND p.status IN ('confirmed', 'self_attested')
  """

  def up do
    # SQL function bodies below refer to tables created after them.
    execute "SET LOCAL check_function_bodies = off"
    execute "CREATE SCHEMA ledger"

    # -- Membership checks used by policies and triggers ---------------------
    # SECURITY DEFINER so policies on `memberships` don't recurse into themselves.

    execute """
    CREATE FUNCTION auth.is_member(gid uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT EXISTS (SELECT 1 FROM memberships m
                        WHERE m.group_id = gid AND m.user_id = auth.uid() AND m.left_at IS NULL)
      $$
    """

    execute """
    CREATE FUNCTION auth.is_admin(gid uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT EXISTS (SELECT 1 FROM memberships m
                        WHERE m.group_id = gid AND m.user_id = auth.uid()
                          AND m.role = 'admin' AND m.left_at IS NULL)
      $$
    """

    execute """
    CREATE FUNCTION auth.shares_group(other uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT EXISTS (SELECT 1 FROM memberships mine
                         JOIN memberships theirs ON theirs.group_id = mine.group_id
                        WHERE mine.user_id = auth.uid() AND mine.left_at IS NULL
                          AND theirs.user_id = other AND theirs.left_at IS NULL)
      $$
    """

    # Writes need an active membership in a group that isn't archived.
    # Archived groups stay readable (and exportable) but nothing in them changes.
    execute """
    CREATE FUNCTION auth.can_write(gid uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT auth.is_member(gid)
           AND NOT EXISTS (SELECT 1 FROM groups g WHERE g.id = gid AND g.deleted_at IS NOT NULL)
      $$
    """

    execute """
    CREATE FUNCTION auth.can_admin(gid uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$ SELECT auth.can_write(gid) AND auth.is_admin(gid) $$
    """

    # Whether `uid` still owes or is owed anything in `gid`, counting payments
    # to them that are waiting for their confirmation. Reads every row (it runs
    # as the owner), not just the ones the caller can see.
    execute """
    CREATE FUNCTION ledger.has_open_balance(gid uuid, uid uuid) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT EXISTS (SELECT 1 FROM balances b
                        WHERE b.group_id = gid
                          AND ((b.debtor_kind = 'user' AND b.debtor_id = uid)
                            OR (b.creditor_kind = 'user' AND b.creditor_id = uid)))
            OR EXISTS (SELECT 1 FROM payments p
                        WHERE p.group_id = gid AND p.to_user_id = uid
                          AND p.status = 'pending' AND p.deleted_at IS NULL)
      $$
    """

    # Whether `uid` is an active member of `gid`, or (with `ever`) was one.
    execute """
    CREATE FUNCTION ledger.is_member_user(gid uuid, uid uuid, ever boolean DEFAULT false) RETURNS boolean
      LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
        SELECT EXISTS (SELECT 1 FROM memberships m
                        WHERE m.group_id = gid AND m.user_id = uid
                          AND (ever OR m.left_at IS NULL))
      $$
    """

    execute """
    CREATE FUNCTION ledger.valid_payment_methods(pm jsonb) RETURNS boolean
      LANGUAGE sql IMMUTABLE
      AS $$
        SELECT jsonb_typeof(pm) = 'array' AND NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(pm) e
           WHERE jsonb_typeof(e) IS DISTINCT FROM 'object'
              OR coalesce(e->>'kind', '') NOT IN #{@payment_methods}
              OR jsonb_typeof(e->'handle') IS DISTINCT FROM 'string')
      $$
    """

    # Stamps `created_by` (or another column) from the person acting.
    execute """
    CREATE FUNCTION ledger.stamp_actor() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF auth.uid() IS NOT NULL THEN
          NEW := jsonb_populate_record(NEW, jsonb_build_object(TG_ARGV[0], auth.uid()));
        END IF;
        RETURN NEW;
      END
      $$
    """

    # -- Tables --------------------------------------------------------------

    execute """
    CREATE TABLE profiles (
      user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
      display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 80),
      payment_methods jsonb NOT NULL DEFAULT '[]' CHECK (ledger.valid_payment_methods(payment_methods)),
      reminder_channel text NOT NULL DEFAULT 'email' CHECK (reminder_channel IN ('email')),
      #{@stamps}
    )
    """

    execute """
    CREATE TABLE groups (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
      created_by uuid NOT NULL REFERENCES users (id),
      deleted_at timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE TABLE memberships (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      user_id uuid NOT NULL REFERENCES users (id),
      role text NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')),
      joined_at timestamp(0) NOT NULL DEFAULT #{@now},
      left_at timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE UNIQUE INDEX memberships_one_active ON memberships (group_id, user_id) WHERE left_at IS NULL
    """

    execute "CREATE INDEX memberships_user ON memberships (user_id)"

    execute """
    CREATE TABLE invites (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
      created_by uuid NOT NULL REFERENCES users (id),
      expires_at timestamp(0) NOT NULL DEFAULT (#{@now} + interval '7 days'),
      used_at timestamp(0),
      used_by uuid REFERENCES users (id),
      revoked_at timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE TABLE counterparties (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
      contact_email text CHECK (char_length(contact_email) <= 254),
      notes text CHECK (char_length(notes) <= 2000),
      created_by uuid NOT NULL REFERENCES users (id),
      deleted_at timestamp(0),
      #{@stamps},
      UNIQUE (id, group_id)
    )
    """

    execute """
    CREATE TABLE categories (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
      created_by uuid NOT NULL REFERENCES users (id),
      deleted_at timestamp(0),
      #{@stamps},
      UNIQUE (id, group_id)
    )
    """

    execute """
    CREATE UNIQUE INDEX categories_unique_name ON categories (group_id, lower(name)) WHERE deleted_at IS NULL
    """

    execute """
    CREATE TABLE expenses (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      description text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 1 AND 200),
      amount_cents bigint NOT NULL CHECK (amount_cents > 0),
      date date NOT NULL,
      category_id uuid,
      paid_by uuid NOT NULL REFERENCES users (id),
      visibility text NOT NULL DEFAULT 'shared' CHECK (visibility IN ('shared', 'private')),
      split jsonb NOT NULL CHECK (jsonb_typeof(split) = 'object' AND split ? 'type'),
      period_start date,
      period_end date CHECK (period_end >= period_start),
      created_by uuid NOT NULL REFERENCES users (id),
      edited_at timestamp(0),
      deleted_at timestamp(0),
      #{@stamps},
      UNIQUE (id, group_id),
      FOREIGN KEY (category_id, group_id) REFERENCES categories (id, group_id)
    )
    """

    execute "CREATE INDEX expenses_group_date ON expenses (group_id, date)"

    execute """
    CREATE TABLE expense_shares (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      expense_id uuid NOT NULL,
      group_id uuid NOT NULL,
      user_id uuid REFERENCES users (id),
      counterparty_id uuid,
      amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
      inserted_at timestamp(0) NOT NULL DEFAULT #{@now},
      CHECK (num_nonnulls(user_id, counterparty_id) = 1),
      FOREIGN KEY (expense_id, group_id) REFERENCES expenses (id, group_id),
      FOREIGN KEY (counterparty_id, group_id) REFERENCES counterparties (id, group_id)
    )
    """

    execute """
    CREATE UNIQUE INDEX expense_shares_one_per_user ON expense_shares (expense_id, user_id)
      WHERE user_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX expense_shares_one_per_counterparty ON expense_shares (expense_id, counterparty_id)
      WHERE counterparty_id IS NOT NULL
    """

    execute """
    CREATE TABLE payments (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      from_user_id uuid REFERENCES users (id),
      from_counterparty_id uuid,
      to_user_id uuid REFERENCES users (id),
      to_counterparty_id uuid,
      amount_cents bigint NOT NULL CHECK (amount_cents > 0),
      date date NOT NULL,
      category_id uuid,
      method text NOT NULL CHECK (method IN #{@payment_methods}),
      reference text CHECK (char_length(reference) <= 200),
      status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'confirmed', 'self_attested', 'declined')),
      recorded_by uuid NOT NULL REFERENCES users (id),
      confirmed_at timestamp(0),
      confirmed_by uuid REFERENCES users (id),
      deleted_at timestamp(0),
      #{@stamps},
      CHECK (num_nonnulls(from_user_id, from_counterparty_id) = 1),
      CHECK (num_nonnulls(to_user_id, to_counterparty_id) = 1),
      CHECK (from_user_id IS NOT NULL OR to_user_id IS NOT NULL),
      CHECK (from_user_id IS DISTINCT FROM to_user_id OR from_user_id IS NULL),
      FOREIGN KEY (from_counterparty_id, group_id) REFERENCES counterparties (id, group_id),
      FOREIGN KEY (to_counterparty_id, group_id) REFERENCES counterparties (id, group_id),
      FOREIGN KEY (category_id, group_id) REFERENCES categories (id, group_id)
    )
    """

    execute "CREATE INDEX payments_group_date ON payments (group_id, date)"

    execute """
    CREATE TABLE audit_log (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      group_id uuid NOT NULL REFERENCES groups (id),
      table_name text NOT NULL,
      row_id uuid NOT NULL,
      action text NOT NULL CHECK (action IN ('insert', 'update', 'soft_delete')),
      actor_id uuid REFERENCES users (id),
      before jsonb,
      after jsonb,
      private_owner_id uuid REFERENCES users (id),
      at timestamp(0) NOT NULL DEFAULT #{@now}
    )
    """

    execute "CREATE INDEX audit_log_group_at ON audit_log (group_id, at)"

    # -- Stamping: who did it comes from auth.uid(), never the client ---------

    for table <- ~w(groups invites counterparties categories expenses) do
      execute """
      CREATE TRIGGER #{table}_stamp_created_by BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION ledger.stamp_actor('created_by')
      """
    end

    execute """
    CREATE TRIGGER payments_stamp_recorded_by BEFORE INSERT ON payments
      FOR EACH ROW EXECUTE FUNCTION ledger.stamp_actor('recorded_by')
    """

    # -- Profiles are made with the user --------------------------------------

    execute """
    CREATE FUNCTION ledger.on_user_created() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        INSERT INTO profiles (user_id, display_name)
        VALUES (NEW.id, left(coalesce(nullif(split_part(NEW.email::text, '@', 1), ''), 'Someone'), 80));
        RETURN NULL;
      END
      $$
    """

    execute """
    CREATE TRIGGER users_create_profile AFTER INSERT ON users
      FOR EACH ROW EXECUTE FUNCTION ledger.on_user_created()
    """

    # -- A new group gets its creator as admin and the starter categories ------

    execute """
    CREATE FUNCTION ledger.on_group_created() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        INSERT INTO memberships (group_id, user_id, role) VALUES (NEW.id, NEW.created_by, 'admin');
        INSERT INTO categories (group_id, name, created_by)
        SELECT NEW.id, c, NEW.created_by
          FROM unnest(ARRAY['Rent', 'Utilities', 'Internet', 'Groceries', 'Dining', 'Travel', 'Other']) AS c;
        RETURN NULL;
      END
      $$
    """

    execute """
    CREATE TRIGGER groups_on_create AFTER INSERT ON groups
      FOR EACH ROW EXECUTE FUNCTION ledger.on_group_created()
    """

    # -- Memberships: admins change roles; members may only leave -------------
    # Leaving yourself takes being even with everyone first. An admin can still
    # remove someone who isn't; their debts stay in the group's balances.

    execute """
    CREATE FUNCTION ledger.guard_membership() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF auth.uid() IS NULL THEN
          RETURN NEW;
        END IF;
        IF OLD.user_id = auth.uid() AND OLD.left_at IS NULL AND NEW.left_at IS NOT NULL
           AND ledger.has_open_balance(OLD.group_id, OLD.user_id) THEN
          RAISE EXCEPTION 'settle up before you leave' USING ERRCODE = 'P0001', HINT = 'unsettled';
        END IF;
        IF auth.is_admin(OLD.group_id) THEN
          RETURN NEW;
        END IF;
        IF OLD.user_id <> auth.uid() OR NEW.role <> OLD.role
           OR OLD.left_at IS NOT NULL OR NEW.left_at IS NULL THEN
          RAISE EXCEPTION 'a member can only leave the group' USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER memberships_guard BEFORE UPDATE ON memberships
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_membership()
    """

    # -- Invites: people can't pre-use them or un-revoke them ------------------

    execute """
    CREATE FUNCTION ledger.guard_invite() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF auth.uid() IS NULL THEN
          RETURN NEW;
        END IF;
        IF TG_OP = 'INSERT' THEN
          NEW.used_at := NULL;
          NEW.used_by := NULL;
          NEW.revoked_at := NULL;
          NEW.expires_at := least(NEW.expires_at, #{@now} + interval '30 days');
        ELSIF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
          RAISE EXCEPTION 'an invite stays revoked' USING ERRCODE = '42501';
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER invites_guard BEFORE INSERT OR UPDATE ON invites
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_invite()
    """

    # -- Expenses: the payer is a member; edits are flagged ----------------------

    execute """
    CREATE FUNCTION ledger.guard_expense() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      BEGIN
        IF (TG_OP = 'INSERT' OR NEW.paid_by IS DISTINCT FROM OLD.paid_by)
           AND NOT ledger.is_member_user(NEW.group_id, NEW.paid_by) THEN
          RAISE EXCEPTION 'whoever paid must be a member of the group' USING ERRCODE = '23514';
        END IF;
        -- Changes to what was spent, by whom, or how it's split mark it edited.
        IF TG_OP = 'UPDATE'
           AND (NEW.description, NEW.amount_cents, NEW.date, NEW.category_id, NEW.paid_by,
                NEW.visibility, NEW.split, NEW.period_start, NEW.period_end)
               IS DISTINCT FROM
               (OLD.description, OLD.amount_cents, OLD.date, OLD.category_id, OLD.paid_by,
                OLD.visibility, OLD.split, OLD.period_start, OLD.period_end) THEN
          NEW.edited_at := #{@now};
        ELSIF TG_OP = 'INSERT' THEN
          NEW.edited_at := NULL;
        END IF;
        RETURN NEW;
      END
      $$
    """

    execute """
    CREATE TRIGGER expenses_guard BEFORE INSERT OR UPDATE ON expenses
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_expense()
    """

    # Shares must add up to the amount, and a private expense has exactly one
    # share: its creator's. Checked at commit (deferred), because an expense and
    # its shares are written in separate statements. `Tab.Ledger` forces the
    # check early with SET CONSTRAINTS so errors surface where they happen.
    execute """
    CREATE FUNCTION ledger.check_expense_shares() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        eid uuid;
        e expenses;
        total bigint;
        n bigint;
        own bigint;
      BEGIN
        IF TG_TABLE_NAME = 'expenses' THEN
          eid := NEW.id;
        ELSIF TG_OP = 'DELETE' THEN
          eid := OLD.expense_id;
        ELSE
          eid := NEW.expense_id;
        END IF;

        SELECT * INTO e FROM expenses WHERE id = eid;
        IF NOT FOUND OR e.deleted_at IS NOT NULL THEN
          RETURN NULL;
        END IF;

        SELECT coalesce(sum(amount_cents), 0), count(*), count(*) FILTER (WHERE user_id = e.created_by)
          INTO total, n, own
          FROM expense_shares WHERE expense_id = eid;

        IF total <> e.amount_cents THEN
          RAISE EXCEPTION 'expense shares add up to % cents, not %', total, e.amount_cents
            USING ERRCODE = '23514';
        END IF;
        IF e.visibility = 'private' AND NOT (n = 1 AND own = 1) THEN
          RAISE EXCEPTION 'a private expense is shared only with its creator' USING ERRCODE = '23514';
        END IF;
        RETURN NULL;
      END
      $$
    """

    execute """
    CREATE CONSTRAINT TRIGGER expenses_shares_add_up AFTER INSERT OR UPDATE ON expenses
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION ledger.check_expense_shares()
    """

    execute """
    CREATE CONSTRAINT TRIGGER expense_shares_add_up AFTER INSERT OR UPDATE OR DELETE ON expense_shares
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION ledger.check_expense_shares()
    """

    # Replaces an expense's shares. The only way shares are written: people
    # have no INSERT on expense_shares. Runs as the owner, so it checks the
    # caller's right to change the expense itself, the same way the update
    # policy on `expenses` does.
    execute """
    CREATE FUNCTION public.set_expense_shares(p_expense_id uuid, p_shares jsonb) RETURNS void
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        e expenses;
        uid uuid := auth.uid();
      BEGIN
        SELECT * INTO e FROM expenses WHERE id = p_expense_id FOR UPDATE;
        IF uid IS NULL OR NOT FOUND OR e.deleted_at IS NOT NULL
           OR NOT auth.can_write(e.group_id)
           OR NOT (e.created_by = uid OR (e.visibility = 'shared' AND auth.is_admin(e.group_id))) THEN
          RAISE EXCEPTION 'you can''t change the shares of this expense' USING ERRCODE = '42501';
        END IF;
        IF jsonb_typeof(p_shares) IS DISTINCT FROM 'array' OR jsonb_array_length(p_shares) = 0 THEN
          RAISE EXCEPTION 'an expense needs at least one share' USING ERRCODE = '23514';
        END IF;

        DELETE FROM expense_shares WHERE expense_id = e.id;

        INSERT INTO expense_shares (expense_id, group_id, user_id, counterparty_id, amount_cents)
        SELECT e.id, e.group_id, s.user_id, s.counterparty_id, s.amount_cents
          FROM jsonb_to_recordset(p_shares) AS s(user_id uuid, counterparty_id uuid, amount_cents bigint);

        IF EXISTS (SELECT 1 FROM expense_shares s
                    WHERE s.expense_id = e.id AND s.user_id IS NOT NULL
                      AND NOT ledger.is_member_user(e.group_id, s.user_id, true)) THEN
          RAISE EXCEPTION 'everyone in a split must be in the group' USING ERRCODE = '23514';
        END IF;
      END
      $$
    """

    # -- Payments: the database decides the status -----------------------------

    execute """
    CREATE FUNCTION ledger.guard_payment() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        uid uuid := auth.uid();
        status_changed boolean := TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status;
        terms_changed boolean := TG_OP = 'INSERT' OR (NEW.from_user_id, NEW.from_counterparty_id,
          NEW.to_user_id, NEW.to_counterparty_id, NEW.amount_cents, NEW.date)
          IS DISTINCT FROM (OLD.from_user_id, OLD.from_counterparty_id,
          OLD.to_user_id, OLD.to_counterparty_id, OLD.amount_cents, OLD.date);
        details_changed boolean := TG_OP = 'UPDATE' AND (terms_changed
          OR (NEW.category_id, NEW.method, NEW.reference, NEW.deleted_at)
             IS DISTINCT FROM (OLD.category_id, OLD.method, OLD.reference, OLD.deleted_at));
      BEGIN
        IF terms_changed
           AND ((NEW.from_user_id IS NOT NULL AND NOT ledger.is_member_user(NEW.group_id, NEW.from_user_id, true))
             OR (NEW.to_user_id IS NOT NULL AND NOT ledger.is_member_user(NEW.group_id, NEW.to_user_id, true))) THEN
          RAISE EXCEPTION 'both sides of a payment must be members or counterparties of the group'
            USING ERRCODE = '23514';
        END IF;

        IF uid IS NOT NULL AND TG_OP = 'UPDATE' THEN
          IF status_changed AND details_changed THEN
            RAISE EXCEPTION 'confirm a payment and edit it in separate steps' USING ERRCODE = '42501';
          ELSIF status_changed THEN
            IF OLD.status <> 'pending' OR NEW.status NOT IN ('confirmed', 'declined')
               OR uid IS DISTINCT FROM OLD.to_user_id THEN
              RAISE EXCEPTION 'only the person paid can confirm or decline a pending payment'
                USING ERRCODE = '42501';
            END IF;
            NEW.confirmed_by := uid;
            NEW.confirmed_at := CASE WHEN NEW.status = 'confirmed' THEN #{@now} END;
            RETURN NEW;
          ELSIF details_changed AND uid IS DISTINCT FROM OLD.recorded_by THEN
            RAISE EXCEPTION 'only whoever recorded a payment can edit it' USING ERRCODE = '42501';
          END IF;
        END IF;

        -- New payments, and payments whose terms changed, get their status from the
        -- parties. Someone who has left can't confirm anything, so a payment with
        -- a former member counts as soon as it's recorded, like a counterparty's.
        IF terms_changed AND (uid IS NOT NULL OR TG_OP = 'INSERT') THEN
          IF NEW.from_counterparty_id IS NOT NULL OR NEW.to_counterparty_id IS NOT NULL
             OR NOT ledger.is_member_user(NEW.group_id, NEW.from_user_id)
             OR NOT ledger.is_member_user(NEW.group_id, NEW.to_user_id) THEN
            NEW.status := 'self_attested';
            NEW.confirmed_at := NULL;
            NEW.confirmed_by := NULL;
          ELSIF NEW.recorded_by = NEW.to_user_id THEN
            NEW.status := 'confirmed';
            NEW.confirmed_at := #{@now};
            NEW.confirmed_by := NEW.recorded_by;
          ELSE
            NEW.status := 'pending';
            NEW.confirmed_at := NULL;
            NEW.confirmed_by := NULL;
          END IF;
        END IF;
        RETURN NEW;
      END
      $$
    """

    # Runs after the recorded_by stamp (triggers fire in name order).
    execute """
    CREATE TRIGGER payments_status BEFORE INSERT OR UPDATE ON payments
      FOR EACH ROW EXECUTE FUNCTION ledger.guard_payment()
    """

    # -- Invites are redeemed in one place ------------------------------------
    # The one SECURITY DEFINER entry point that writes a membership: it can't
    # know the group until the token is checked. Every failure looks the same,
    # so a guess learns nothing.
    execute """
    CREATE FUNCTION public.accept_invite(token text) RETURNS uuid
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        inv invites;
        uid uuid := auth.uid();
      BEGIN
        IF uid IS NULL THEN
          RAISE EXCEPTION 'sign in to accept an invite' USING ERRCODE = '42501';
        END IF;

        SELECT * INTO inv FROM invites
         WHERE token_hash = sha256(convert_to(token, 'UTF8'))
         FOR UPDATE;

        IF NOT FOUND OR inv.used_at IS NOT NULL OR inv.revoked_at IS NOT NULL
           OR inv.expires_at <= #{@now}
           OR EXISTS (SELECT 1 FROM groups g WHERE g.id = inv.group_id AND g.deleted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'this invite link is not valid' USING ERRCODE = 'P0001', HINT = 'invalid_invite';
        END IF;

        IF ledger.is_member_user(inv.group_id, uid) THEN
          RAISE EXCEPTION 'you are already in this group' USING ERRCODE = 'P0001', HINT = 'already_member';
        END IF;

        UPDATE invites SET used_at = #{@now}, used_by = uid, updated_at = #{@now} WHERE id = inv.id;
        INSERT INTO memberships (group_id, user_id, role) VALUES (inv.group_id, uid, 'member');
        RETURN inv.group_id;
      END
      $$
    """

    # -- Audit log: written by triggers, never changed ------------------------

    execute """
    CREATE FUNCTION ledger.audit() RETURNS trigger
      LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public
      AS $$
      DECLARE
        b jsonb;
        a jsonb := to_jsonb(NEW) - 'token_hash';
        act text := 'insert';
        owner uuid;
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          b := to_jsonb(OLD) - 'token_hash';
          act := CASE WHEN b->>'deleted_at' IS NULL AND a->>'deleted_at' IS NOT NULL
                      THEN 'soft_delete' ELSE 'update' END;
        END IF;

        IF TG_TABLE_NAME = 'expenses'
           AND 'private' IN (a->>'visibility', coalesce(b->>'visibility', '')) THEN
          owner := (a->>'created_by')::uuid;
        END IF;

        INSERT INTO audit_log (group_id, table_name, row_id, action, actor_id, before, after, private_owner_id)
        VALUES (
          CASE WHEN TG_TABLE_NAME = 'groups' THEN (a->>'id')::uuid ELSE (a->>'group_id')::uuid END,
          TG_TABLE_NAME, (a->>'id')::uuid, act, auth.uid(), b, a, owner);
        RETURN NULL;
      END
      $$
    """

    for table <- ~w(groups memberships invites counterparties categories expenses payments) do
      execute """
      CREATE TRIGGER #{table}_audit AFTER INSERT OR UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION ledger.audit()
      """
    end

    execute """
    CREATE FUNCTION ledger.audit_is_append_only() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'the audit log is append-only' USING ERRCODE = '42501';
      END
      $$
    """

    execute """
    CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
      FOR EACH ROW EXECUTE FUNCTION ledger.audit_is_append_only()
    """

    execute """
    CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
      FOR EACH STATEMENT EXECUTE FUNCTION ledger.audit_is_append_only()
    """

    # -- Balances: computed, never stored --------------------------------------
    # security_invoker: each person sees balances built only from rows their
    # own policies let them read.

    execute """
    CREATE VIEW balances WITH (security_invoker = true) AS
    WITH flows AS (#{@flows}),
    oriented AS (
      SELECT group_id,
             (debtor_kind, debtor_id) < (creditor_kind, creditor_id) AS forward,
             debtor_kind, debtor_id, creditor_kind, creditor_id, amount_cents
        FROM flows
    ),
    net AS (
      SELECT group_id,
             CASE WHEN forward THEN debtor_kind ELSE creditor_kind END AS a_kind,
             CASE WHEN forward THEN debtor_id ELSE creditor_id END AS a_id,
             CASE WHEN forward THEN creditor_kind ELSE debtor_kind END AS b_kind,
             CASE WHEN forward THEN creditor_id ELSE debtor_id END AS b_id,
             sum(CASE WHEN forward THEN amount_cents ELSE -amount_cents END)::bigint AS a_owes_b
        FROM oriented
       GROUP BY 1, 2, 3, 4, 5
    )
    SELECT group_id,
           CASE WHEN a_owes_b > 0 THEN a_kind ELSE b_kind END AS debtor_kind,
           CASE WHEN a_owes_b > 0 THEN a_id ELSE b_id END AS debtor_id,
           CASE WHEN a_owes_b > 0 THEN b_kind ELSE a_kind END AS creditor_kind,
           CASE WHEN a_owes_b > 0 THEN b_id ELSE a_id END AS creditor_id,
           abs(a_owes_b) AS amount_cents
      FROM net
     WHERE a_owes_b <> 0
    """

    execute """
    CREATE VIEW category_balances WITH (security_invoker = true) AS
    WITH flows AS (#{@flows}),
    oriented AS (
      SELECT group_id, category_id,
             (debtor_kind, debtor_id) < (creditor_kind, creditor_id) AS forward,
             debtor_kind, debtor_id, creditor_kind, creditor_id, amount_cents
        FROM flows
       WHERE category_id IS NOT NULL
    ),
    net AS (
      SELECT group_id, category_id,
             CASE WHEN forward THEN debtor_kind ELSE creditor_kind END AS a_kind,
             CASE WHEN forward THEN debtor_id ELSE creditor_id END AS a_id,
             CASE WHEN forward THEN creditor_kind ELSE debtor_kind END AS b_kind,
             CASE WHEN forward THEN creditor_id ELSE debtor_id END AS b_id,
             sum(CASE WHEN forward THEN amount_cents ELSE -amount_cents END)::bigint AS a_owes_b
        FROM oriented
       GROUP BY 1, 2, 3, 4, 5, 6
    )
    SELECT group_id, category_id,
           CASE WHEN a_owes_b > 0 THEN a_kind ELSE b_kind END AS debtor_kind,
           CASE WHEN a_owes_b > 0 THEN a_id ELSE b_id END AS debtor_id,
           CASE WHEN a_owes_b > 0 THEN b_kind ELSE a_kind END AS creditor_kind,
           CASE WHEN a_owes_b > 0 THEN b_id ELSE a_id END AS creditor_id,
           abs(a_owes_b) AS amount_cents
      FROM net
     WHERE a_owes_b <> 0
    """
  end

  def down do
    execute "DROP VIEW category_balances"
    execute "DROP VIEW balances"
    execute "DROP FUNCTION public.accept_invite(text)"
    execute "DROP FUNCTION public.set_expense_shares(uuid, jsonb)"
    execute "DROP TRIGGER users_create_profile ON users"

    for table <-
          ~w(audit_log payments expense_shares expenses categories counterparties invites memberships groups profiles) do
      execute "DROP TABLE #{table}"
    end

    execute "DROP FUNCTION auth.can_admin(uuid)"
    execute "DROP FUNCTION auth.can_write(uuid)"
    execute "DROP FUNCTION auth.shares_group(uuid)"
    execute "DROP FUNCTION auth.is_admin(uuid)"
    execute "DROP FUNCTION auth.is_member(uuid)"
    execute "DROP SCHEMA ledger CASCADE"
  end
end
