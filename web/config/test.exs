import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tab, Tab.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tab_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tab, TabWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "cGozmSMoPIarp/5jeS5GZybvlQZnFPDgpUtP0omOJuWiUZCM6uzAat6zEh8j3Y2R",
  server: false

# In test we don't send emails
config :tab, Tab.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Jobs run inline in tests; nothing polls the database.
config :tab, Oban, testing: :manual

# Phase 4: a receiving domain and webhook secret, and both outside services
# answered by Req.Test stubs, never the network.
config :tab,
  inbound_domain: "bills.test",
  resend_webhook_secret: "whsec_" <> Base.encode64("tab-test-webhook-secret-32-bytes"),
  resend_api_key: "re_test",
  reads_per_day: 30,
  resend_req: [plug: {Req.Test, Tab.Inbox.Resend}],
  reader_req: [plug: {Req.Test, Tab.Reader}]

# Phase 5: client metadata documents come from a Req.Test stub, and hosts
# ending in .example resolve to a public address without DNS.
config :tab,
  cimd_req: [plug: {Req.Test, Tab.OAuth.CIMD}],
  cimd_resolver: {Tab.TestResolver, :resolve}

# Phase 6: Paddle's sandbox, answered by a Req.Test stub.
config :tab, :paddle,
  env: "sandbox",
  api_key: "pdl_test",
  client_token: "test_client_token",
  webhook_secret: "pdl_ntfset_test_secret",
  plus_price_id: "pri_plus",
  pro_price_id: "pri_pro"

config :tab, paddle_req: [plug: {Req.Test, Tab.Billing.Paddle}]
