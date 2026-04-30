# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tabletop, :scopes,
  user: [
    default: true,
    module: Tabletop.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Tabletop.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :tabletop,
  ecto_repos: [Tabletop.Repo],
  generators: [timestamp_type: :utc_datetime]

# Emails allowed to access the tournament admin console.
# Overridable in runtime.exs via the ADMIN_EMAILS env var.
config :tabletop, :admin_emails, []

config :tabletop, Tabletop.Repo, migration_primary_key: [type: :uuid]

# Configure the endpoint
config :tabletop, TabletopWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TabletopWeb.ErrorHTML, json: TabletopWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tabletop.PubSub,
  live_view: [signing_salt: "xX9xDs/8"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tabletop, Tabletop.Mailer,
  adapter: Swoosh.Adapters.Local,
  from_name: "Tabletop",
  from_email: "contact@example.com"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tabletop: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  scanner_worker: [
    args:
      ~w(js/card_scanner/scanner_worker.js --bundle --target=es2022 --outdir=../priv/static/assets/js/card_scanner),
    cd: Path.expand("../assets", __DIR__),
    env: %{}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  tabletop: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
