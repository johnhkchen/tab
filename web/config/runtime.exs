import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tab start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tab, TabWeb.Endpoint, server: true
end

config :tab, TabWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :tab, TabWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/tab_web/router\.ex$"E,
        ~r"lib/tab_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# One currency per instance; amounts are whole cents of it.
config :tab, :currency, System.get_env("TAB_CURRENCY", "USD") |> String.upcase()

if extract_url = System.get_env("EXTRACT_URL") do
  config :tab, :extract_url, extract_url
end

# Receiving forwarded bills through Resend (docs/specification.md, "Configuration").
# compose.yaml passes unset settings as empty strings; those count as unset.
env = fn name -> if (value = System.get_env(name)) not in [nil, ""], do: value end

if config_env() != :test do
  config :tab,
    inbound_domain: env.("TAB_INBOUND_DOMAIN"),
    resend_webhook_secret: env.("RESEND_WEBHOOK_SECRET"),
    resend_api_key: env.("RESEND_API_KEY"),
    reads_per_day: String.to_integer(env.("TAB_READS_PER_DAY") || "30")
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tab, Tab.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :tab, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tab, TabWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tab, TabWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tab, TabWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Outbound mail (docs/specification.md, "Outbound mail"). Tab never runs a
  # mail server; it hands mail to a provider. Resend if RESEND_API_KEY is set,
  # else SMTP if SMTP_HOST is set, else the log: sign-in links are printed there
  # so a fresh install can still be signed into.
  # compose.yaml passes unset settings through as empty strings; treat those as unset.
  mail_env = fn name -> if (value = System.get_env(name)) not in [nil, ""], do: value end
  mail_from = mail_env.("TAB_MAIL_FROM") || "tab@#{host}"
  config :tab, :mail_from, {"Tab", mail_from}

  cond do
    api_key = mail_env.("RESEND_API_KEY") ->
      config :tab, Tab.Mailer, adapter: Swoosh.Adapters.Resend, api_key: api_key

    smtp_host = mail_env.("SMTP_HOST") ->
      config :tab, Tab.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(mail_env.("SMTP_PORT") || "587"),
        username: mail_env.("SMTP_USERNAME"),
        password: mail_env.("SMTP_PASSWORD"),
        auth: if(mail_env.("SMTP_USERNAME"), do: :always, else: :never),
        # Port 465 is TLS from the start; anything else upgrades with STARTTLS,
        # required unless SMTP_TLS=if_available (a local relay without TLS).
        ssl: mail_env.("SMTP_PORT") == "465",
        tls: if(mail_env.("SMTP_TLS") == "if_available", do: :if_available, else: :always),
        retries: 2

    true ->
      config :tab, Tab.Mailer,
        adapter: Swoosh.Adapters.Logger,
        log_full_email: true,
        level: :warning
  end
end
