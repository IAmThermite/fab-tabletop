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
# Overridable in runtime.exs via the FABTABLETOP_ADMIN_IDS env var.
config :tabletop, :admin_ids, []

# User ids allowed to reach the LiveDashboard (`/dev/dashboard`) outside of
# development, where the route is open. Overridable in runtime.exs via the
# LIVE_DASHBOARD_USER_IDS env var. Empty list = nobody, so the dashboard is
# closed by default on a fresh deploy.
config :tabletop, :live_dashboard_user_ids, []

# How often `Tabletop.Games.HeroLeaderboard` recomputes the lobby's
# popular-heroes ranking. It covers a 7-day window, so it barely moves between
# refreshes; `nil` disables refreshing and makes every read compute inline.
config :tabletop, :hero_leaderboard_refresh_ms, :timer.minutes(30)

config :tabletop, Tabletop.Repo, migration_primary_key: [type: :uuid]

# WebRTC TURN/STUN. STUN-only by default (safe for test); dev.exs points at the
# local coturn and runtime.exs reads TURN_SECRET/TURN_URLS in prod.
config :tabletop, Tabletop.Turn, secret: nil, urls: []

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

# Prometheus metrics. The scrape endpoint is served by
# `Tabletop.PromEx.MetricsServer` on its own port (see `:metrics_port` per env)
# so it is never routable through the public endpoint.
#
# `grafana: :disabled` — dashboards are imported into Grafana manually rather
# than pushed from the app on boot. See `Tabletop.PromEx.dashboards/0` for the
# list; export them with `mix prom_ex.dashboard.export --dashboard <name>`.
config :tabletop, Tabletop.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

config :tabletop, :metrics_port, 9091

# OpenTelemetry tracing → Grafana Tempo. See `Tabletop.Tracing`.
#
# `traces_exporter: :none` is the default on purpose: the exporter would
# otherwise target http://localhost:4318 and log a failure for every batch.
# `runtime.exs` flips this to `:otlp` only when OTEL_EXPORTER_OTLP_ENDPOINT is
# set, so tracing is opt-in per environment.
config :opentelemetry,
  traces_exporter: :none,
  span_processor: :batch,
  resource: [service: [name: "tabletop"]],
  # Installed as the `root` of the default parent_based sampler, so child spans
  # keep inheriting their parent's decision — dropping a health-check root also
  # drops the Ecto spans beneath it. See `Tabletop.Tracing.PathSampler`.
  sampler:
    {:parent_based,
     %{root: {Tabletop.Tracing.PathSampler, %{ignore_paths: ["/health", "/metrics"]}}}}

# Grafana Cloud's OTLP gateway speaks protobuf over HTTP. This is also the
# library default, but stating it keeps the grpc path (and grpcbox) unused.
config :opentelemetry_exporter, otlp_protocol: :http_protobuf

# Error tracking. Complements rather than overlaps the Grafana stack: Tempo
# records exceptions but has no issue model (no grouping, dedup, or "this is
# new"), and metrics cannot see a crash at all.
#
# No `dsn` here on purpose — Sentry reads SENTRY_DSN from the environment
# itself, and with no DSN it is disabled outright. So dev and test are silent
# without any per-env opt-out, and production only needs the secret set.
#
# Source context requires `mix sentry.package_source_code` before `mix release`
# (see infrastructure/Dockerfile); without it the events still arrive, just
# without surrounding source lines.
config :sentry,
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
