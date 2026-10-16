defmodule Tab.Repo.Migrations.CreateBilling do
  @moduledoc """
  Phase 6 (docs/specification.md, "Phase 6"): what Hosted Tab needs to know
  about plans. Billing accounts, the trial-once list, extension requests,
  Paddle's webhook events, and reads counted for allowances. On self-host
  these stay empty.

  People read their own billing account, requests, and reads. Only
  `Tab.Billing`, as the connection owner, changes billing fields.
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
    billing_accounts: {["SELECT"], %{select: @mine, insert: nil, update: nil}},
    trial_emails: {[], %{select: nil, insert: nil, update: nil}},
    extension_requests: {
      ["SELECT", "INSERT"],
      %{
        select: @mine,
        insert: "#{@mine} AND status = 'waiting' AND decided_at IS NULL",
        update: nil
      }
    },
    paddle_events: {[], %{select: nil, insert: nil, update: nil}},
    reads: {["SELECT"], %{select: @mine, insert: nil, update: nil}}
  ]

  def up do
    execute """
    CREATE TABLE billing_accounts (
      user_id uuid PRIMARY KEY REFERENCES users (id),
      paid_plan text CHECK (paid_plan IN ('plus', 'pro')),
      paid_until timestamp(0),
      paddle_customer_id text CHECK (char_length(paddle_customer_id) <= 100),
      paddle_subscription_id text UNIQUE CHECK (char_length(paddle_subscription_id) <= 100),
      subscription_status text CHECK (char_length(subscription_status) <= 40),
      -- The newest Paddle event applied, so an older one never overwrites it.
      subscription_event_at timestamp(6),
      trial_until timestamp(0),
      -- The month (its first day) the 80% email went out.
      warned_month date,
      #{@stamps}
    )
    """

    execute """
    CREATE TABLE trial_emails (
      email_hash bytea PRIMARY KEY CHECK (octet_length(email_hash) = 32),
      inserted_at timestamp(0) NOT NULL DEFAULT #{@now}
    )
    """

    execute """
    CREATE TABLE extension_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id),
      question text NOT NULL CHECK (char_length(question) BETWEEN 1 AND 300),
      answer text NOT NULL CHECK (char_length(btrim(answer)) BETWEEN 1 AND 2000),
      may_quote boolean NOT NULL DEFAULT false,
      status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'granted', 'declined')),
      decided_at timestamp(0),
      #{@stamps}
    )
    """

    execute """
    CREATE UNIQUE INDEX extension_requests_one_waiting
      ON extension_requests (user_id) WHERE status = 'waiting'
    """

    execute """
    CREATE TABLE paddle_events (
      event_id text PRIMARY KEY CHECK (char_length(event_id) <= 100),
      event_type text NOT NULL CHECK (char_length(event_type) <= 100),
      occurred_at timestamp(6) NOT NULL,
      payload jsonb NOT NULL,
      processed_at timestamp(0),
      inserted_at timestamp(0) NOT NULL DEFAULT #{@now}
    )
    """

    execute """
    CREATE TABLE reads (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id),
      document_id uuid,
      paid boolean NOT NULL,
      read_on date NOT NULL DEFAULT (#{@now})::date,
      inserted_at timestamp(0) NOT NULL DEFAULT #{@now}
    )
    """

    execute "CREATE INDEX reads_user_month ON reads (user_id, read_on)"

    execute """
    CREATE TRIGGER extension_requests_stamp_user BEFORE INSERT ON extension_requests
      FOR EACH ROW EXECUTE FUNCTION ledger.stamp_actor('user_id')
    """

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
  end

  def down do
    for table <- ~w(reads paddle_events extension_requests trial_emails billing_accounts) do
      execute "DROP TABLE #{table} CASCADE"
    end
  end
end
