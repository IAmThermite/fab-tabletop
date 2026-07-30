# Fly.io Deployment

## Prerequisites

- [flyctl](https://fly.io/docs/flyctl/install/) installed
- Fly.io account (`fly auth signup`)

## Initial Setup

### 1. Create the Postgres database app

```bash
# Create the database app
fly launch --config infrastructure/fly/postgres.toml --no-deploy

# Create a 1GB persistent volume for data
fly volumes create pg_data --size 1 --region iad --app fabtabletop-db

# Set the Postgres password
fly secrets set POSTGRES_PASSWORD=<your-secure-password> --app fabtabletop-db

# Deploy Postgres
fly deploy --config infrastructure/fly/postgres.toml
```

### 2. Create the web app

All `fly deploy` commands must be run from the **repo root** because the Dockerfile
references paths relative to the repo root (e.g. `tabletop/config/`).

```bash
# Create the app (skip deploy on first run)
fly launch --config infrastructure/fly/fly.toml --no-deploy

# Set secrets — DATABASE_URL uses Fly's private DNS (.internal) to reach the db app
# Note: .internal uses IPv6 (Fly 6PN), so the ECTO_IPV6=true env var is needed
fly secrets set \
  DATABASE_URL="ecto://fabtabletop:<your-secure-password>@fabtabletop-db.internal:5432/fabtabletop" \
  SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
```

To deploy:

```bash
fly deploy --config infrastructure/fly/fly.toml
```

## Custom Domain

```bash
# Add your domain
fly certs add yourdomain.com

# Fly will output instructions — create a CNAME or A record at your DNS provider:
#   CNAME: yourdomain.com -> fabtabletop.fly.dev
#   (or use the IPv4/IPv6 addresses for an A/AAAA record on apex domains)
```

## Useful Commands

```bash
fly status                          # App status and machine info
fly status --app fabtabletop-db     # Database status
fly logs                            # Stream live logs
fly ssh console                     # SSH into the web app machine
fly ssh console --app fabtabletop-db  # SSH into the database machine
fly scale show                      # Current VM size and count
fly secrets list                    # List configured secrets
```

## Database Migrations

To run manually:

```bash
fly ssh console -c infrastructure/fly/fly.toml -C "/app/bin/tabletop eval 'Tabletop.Release.migrate()'"
```

To seed the Card database run:

```bash
fly ssh console -c infrastructure/fly/fly.toml -C "/app/bin/tabletop eval 'Tabletop.Release.import_cards()'"
```

## Database Backups

The self-hosted Postgres runs on a persistent volume. To back up manually:

```bash
# pg_dump from the database machine
fly ssh console --app fabtabletop-db -C "pg_dump -U fabtabletop fabtabletop" > backup.sql
```

## Deploy Troubleshooting

**`failed to compute cache key: failed to walk /tmp/buildkit-mountNNNN/tabletop/config: no such file or directory`**

The remote builder's context cache is stale — the path exists locally and in
`.dockerignore` terms is fine, but a previous interrupted build left a cache
record pointing at a mount that no longer exists. Deploy once with `--no-cache`:

```bash
fly deploy --config infrastructure/fly/fly.toml --no-cache
```

Subsequent deploys can drop the flag. If it recurs persistently, destroy the
builder app (`fly apps list` → `fly-builder-*`) so a fresh one is provisioned.

**`release command failed` with `tcp connect (fabtabletop-db.internal:5432): non-existing domain - :nxdomain`**

The database machine is stopped. Fly's `.internal` DNS only returns records for
machines that are actually running, so a stopped Postgres resolves to nothing
rather than to a refused connection. Start it and redeploy:

```bash
fly status --app fabtabletop-db          # check machine STATE
fly machine start <machine-id> --app fabtabletop-db
```

## Monitoring

Metrics are exposed by `Tabletop.PromEx.MetricsServer` on port **9091**, declared
in the `[metrics]` block of `fly.toml`. Fly scrapes that port every 15s over the
private 6PN network and stores the samples in its managed Prometheus.

The port is deliberately **not** part of `[http_service]`, so the scrape endpoint
is unreachable from the public internet and needs no auth of its own. Nothing on
the public endpoint routes to `/metrics`.

### Viewing dashboards

Fly ships a managed Grafana at [fly-metrics.net](https://fly-metrics.net),
pre-wired to your Prometheus with dashboards for the platform metrics (CPU,
memory, HTTP, machine state).

To query the same data from your own Grafana — which you need for the app-level
metrics — add a Prometheus data source:

Create an **org-scoped read-only** token — this is the part that trips people up:

```bash
fly tokens create readonly -o personal -n grafana -x 8760h
```

Then configure the data source:

```
Type: Prometheus
URL:  https://api.fly.io/prometheus/personal/     # base only — Grafana appends /api/v1
Auth: Custom HTTP Headers →
        Header: Authorization
        Value:  <paste the entire CLI output — it already starts with "FlyV1 ">
```

Leave *Basic auth* and the Bearer/credentials fields empty. The org slug is
`personal` for this account (`fly orgs list` to confirm).

**Token scope is the common failure.** Fly's Prometheus is an org-level resource,
so an app-scoped token authenticates but is not authorized. Only
`fly tokens create readonly` produces an org-scoped token — `deploy` and `org`
are both deploy-scoped and will fail. Tested against `/api/v1/query`:

| Token | Result |
| --- | --- |
| `fly tokens create readonly -o personal` | `200` |
| `fly tokens create deploy -a fabtabletop` | `403 not authorized for org` |

Read the status code to tell the two failure modes apart:

- **403 `not authorized for org`** — token is app-scoped; mint a `readonly` one.
- **401 `something went wrong resolving organization`** — wrong auth scheme or
  wrong org slug. `Bearer <token>` gives this; the macaroon needs `FlyV1`.

Doubling the prefix (`FlyV1 FlyV1 fm2_…`, easy to do since the CLI output already
includes it) is tolerated and still returns `200`, so it is not worth chasing.

Verified working:

```bash
TOKEN=$(fly tokens create readonly -o personal -x 1h | tail -1)   # includes "FlyV1 "
curl -s -G -H "Authorization: $TOKEN" \
  --data-urlencode 'query=tabletop_prom_ex_game_sessions_active' \
  https://api.fly.io/prometheus/personal/api/v1/query
```

### Dashboards

`Tabletop.PromEx.dashboards/0` lists the pre-built PromEx dashboards for Phoenix,
Ecto, LiveView, the BEAM and application metadata. Export one to import into
Grafana by hand:

```bash
mix prom_ex.dashboard.export --dashboard phoenix.json --stdout
```

The app-specific metrics (`tabletop_prom_ex_game_*`) have no pre-built dashboard
— see the moduledoc on `Tabletop.PromEx.GamePlugin` for what each one answers.

### Verifying the scrape locally

```bash
mix phx.server
curl -s localhost:9091/metrics | grep tabletop_prom_ex_game
```

Counters only appear once their event has fired at least once, so a freshly
booted server shows the polled gauges but not yet the event counters.

## Tracing (Grafana Tempo)

Traces are **pushed** over OTLP rather than scraped, which is what makes them work
on a scale-to-zero machine — there is no poll to miss while it sleeps. Wiring
lives in `Tabletop.Tracing`; spans come from Bandit (HTTP), Phoenix (endpoint,
router **and LiveView** callbacks) and Ecto (one span per query, with the
parameterised SQL attached).

### Enabling it

Tracing is off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set — the exporter's
default target is `http://localhost:4318`, and with nothing there every batch
fails and logs. Get the endpoint, instance ID and a token from Grafana Cloud
(**Connections → OpenTelemetry (OTLP)**), then:

```bash
fly secrets set \
  OTEL_EXPORTER_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-3.grafana.net/otlp" \
  GRAFANA_CLOUD_INSTANCE_ID="<numeric instance id>" \
  GRAFANA_CLOUD_OTLP_TOKEN="<access policy token with traces:write>"
```

or

```bash
fly secrets set \
  OTEL_EXPORTER_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-3.grafana.net/otlp" \
  OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic..."
```

Notes:

- Use the **base** gateway URL ending in `/otlp`. The exporter appends
  `v1/traces` itself. Set `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` instead if you
  need to give a complete URL with no suffix appended.
- Pick the zone matching your Grafana stack (`prod-us-east-0`, `prod-eu-west-2`, …)
  — it is not necessarily the Fly region.
- `runtime.exs` builds the HTTP Basic header from the instance ID and token, so
  you never hand-roll base64. To use a non-Grafana backend, set
  `OTEL_EXPORTER_OTLP_HEADERS` (standard `key=value,key2=value2` form) and it
  takes precedence.
- Setting the endpoint without credentials **raises on boot** rather than
  silently exporting nothing.

### `401 authentication error: no credentials provided`

Note the wording — Grafana is saying **no** credentials arrived, not that they were
wrong. The cause is percent-encoding. Grafana's generated snippet reads:

```
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic%20<base64>
```

The exporter re-reads that variable from the OS environment, and
`otel_configuration:merge_list_with_environment/3` ranks OS env **above** app
env — so it wins over anything `runtime.exs` computes. Its `key_value_list`
parser splits on `=` and strips quotes but never percent-decodes, so the header
goes out as `Basic%20<base64>`: no space, therefore no recognisable auth scheme,
therefore "no credentials provided".

`runtime.exs` now normalises the variable in place (decoding `%20` and writing
the canonical form back with `System.put_env/2` before any application starts),
so the pasted snippet works as-is. On an older build, set the secret with a
**real space** instead:

```bash
fly secrets set OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64>"
```

Either form is fine now. The same OS-over-app-env precedence applies to every
`OTEL_*` variable, so prefer setting those directly over adding app config that
they would silently override.

### Filtered paths

`/health` and `/metrics` produce no traces. Fly polls the health check on its
`interval` and scrapes metrics every 15s, so together they would be thousands of
identical spans a day — noise in Tempo, and billed like any other span on
Grafana Cloud.

The filtering is a sampler (`Tabletop.Tracing.PathSampler`), not a plug:
`opentelemetry_bandit` has no ignore-path option, and its telemetry handler is
global, so the `Tabletop.PromEx.MetricsServer` listener on 9091 emits spans from
the same handler as the main endpoint. A sampler catches both, and decides at
span start before any attribute enrichment.

It is installed as the `root` of the default `parent_based` sampler in
`config.exs`, so child spans still inherit their parent's decision — the Ecto
queries inside a dropped health check disappear with it, no second rule needed.
Matching is exact, so `/health-history` is still traced. Spans with no
`url.path` (an Ecto query from a `GameSession`, say) are always kept.

To change the list, edit `:ignore_paths` in the `sampler:` config in
`config/config.exs`.

### Checking it

```bash
# Is the exporter live, or are spans being built and dropped?
fly ssh console -C "/app/bin/tabletop rpc 'IO.inspect(Tabletop.Tracing.exporting?())'"
```

Then hit the app and look for a `tabletop` service in Tempo. Failed exports log
from `opentelemetry_exporter`, so `fly logs` shows auth or endpoint problems.

To inspect spans locally without a backend, temporarily add to `config/dev.exs`:

```elixir
config :opentelemetry, traces_exporter: {:otel_exporter_stdout, []}
```

`mix phx.server` then prints every span, which is how the instrumentation above
was verified.

### Caveat: scale-to-zero

`fly.toml` sets `auto_stop_machines = 'stop'` with `min_machines_running = 0`.
Metrics live in the machine's memory, so counters reset on every cold start and
gauges gap while the machine is stopped. Use `rate()`/`increase()` in queries —
they account for counter resets — and don't read a gap as a zero.

## Environment

- **PHX_HOST**: Set in fly.toml — update this after adding a custom domain
- **DATABASE_URL**: Set via `fly secrets set`, uses Fly private DNS (`.internal`, IPv6)
- **ECTO_IPV6**: Set in fly.toml — required because `.internal` DNS resolves to IPv6
- **SECRET_KEY_BASE**: Set via `fly secrets set`
- **METRICS_PORT**: Optional, defaults to `9091` — must match `[metrics]` in fly.toml
