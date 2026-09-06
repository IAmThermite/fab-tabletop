# Monitoring & Observability

Setup guide for the four signals this deployment produces, and the provider-side
configuration each one needs.

| Signal | Emitted by | Stored in | Answers |
| --- | --- | --- | --- |
| **Metrics** | PromEx → `/metrics` on :9091 | Fly's managed Prometheus | "Is it healthy? What are the rates?" |
| **Traces** | OpenTelemetry → OTLP push | Grafana Cloud Tempo | "Why was *this* request slow?" |
| **Errors** | Sentry SDK | Sentry | "What broke, is it new, how often?" |
| **Database** | Grafana Alloy, reading Postgres | Grafana Cloud | "Which query is slow, and why that plan?" |

They overlap less than they appear. Metrics catch **working-but-wrong** — a card
that fails to scan raises no exception, so only the scanner hit-rate metric will
ever tell you the pHash thresholds have drifted. Sentry catches **crashed** and,
unlike Tempo, groups and dedupes them into issues with "this is new since the
last release". Tempo records exceptions too, but has no issue model, so you have
to already suspect a problem to go looking for it.

The database signal is the odd one out: **no application code participates**. The
first three are emitted by the app, so they see a query only as the Ecto span that
issued it. Alloy reads Postgres' own catalogs instead, which is the only place the
plan, the index usage and the statistics behind a regression exist — Ecto never
knows why its query was slow.

Files in this directory:

| File | What it is |
| --- | --- |
| `db-o11y-setup.sql` | Creates the read-only `db-o11y` role and its grants; run once per database |
| `config.alloy` | The Alloy collector pipeline |
| `alloy.Dockerfile` | Alloy image with `config.alloy` baked in |
| `alloy.toml` | Fly app config for the collector |

---

## Prerequisites

- A **Grafana Cloud** account (free tier is sufficient) — used for both the
  dashboards and Tempo.
- A **Sentry** account and project (Elixir platform).
- `flyctl`, authenticated (`fly auth login`).

Run all commands from the repo root.

---

## 1. Metrics → Fly Prometheus → Grafana

### How it works

`Tabletop.PromEx.MetricsServer` serves Prometheus text on port **9091**, declared
in the `[metrics]` block of `infrastructure/fly/fly.toml`:

```toml
[metrics]
  port = 9091
  path = "/metrics"
```

Fly scrapes that port every 15s over the private network and stores the
samples in its own managed Prometheus.

The port is deliberately **not** part of `[http_service]`, so `/metrics` is
unreachable from the public internet and needs no auth of its own. Nothing on the
public endpoint routes to it.

### Adding the data source to your own Grafana

**Step 1 — mint an org-scoped read-only token.**

```bash
fly tokens create readonly -o personal -n grafana -x 8760h
```

**Step 2 — configure the data source:**

```
Type: Prometheus
URL:  https://api.fly.io/prometheus/personal/     # base only — Grafana appends /api/v1
Auth: Custom HTTP Headers →
        Header: Authorization
        Value:  <paste the entire CLI output — it already begins with "FlyV1 ">
```

Leave *Basic auth* and the Bearer/credentials fields empty. Confirm org slug
with `fly orgs list`; it is `personal` for this account.

### Token scope is the usual failure

Fly's Prometheus is an **org-level** resource, so an app-scoped token
authenticates fine and is then refused. Only `readonly` produces an org-scoped
token — `deploy` and `org` are both deploy-scoped. Tested against
`/api/v1/query`:

| Token | Result |
| --- | --- |
| `fly tokens create readonly -o personal` | `200` |
| `fly tokens create deploy -a fabtabletop` | `403 not authorized for org` |

Use the status code to tell the two failure modes apart:

- **403 `not authorized for org`** — token is app-scoped. Mint a `readonly` one.
- **401 `something went wrong resolving organization`** — wrong auth scheme or
  wrong org slug. `Bearer <token>` produces this; the macaroon needs `FlyV1`.

Doubling the prefix (`FlyV1 FlyV1 fm2_…` — easy, since the CLI output already
includes it) is tolerated and still returns `200`. Not worth chasing.

Verify from the command line:

```bash
TOKEN=$(fly tokens create readonly -o personal -x 1h | tail -1)   # includes "FlyV1 "
curl -s -G -H "Authorization: $TOKEN" \
  --data-urlencode 'query=tabletop_prom_ex_game_sessions_active' \
  https://api.fly.io/prometheus/personal/api/v1/query
```

### Dashboards

`Tabletop.PromEx.dashboards/0` lists pre-built PromEx dashboards for Phoenix,
Ecto, LiveView, the BEAM and application metadata. Export one to import by hand:

```bash
mix prom_ex.dashboard.export --dashboard phoenix.json --stdout
```

The app-specific metrics (`tabletop_prom_ex_game_*`) have no pre-built dashboard.
See the moduledoc on `Tabletop.PromEx.GamePlugin` for what each one answers —
scanner hit rate, Swiss pairing duration, active sessions, leave timers and
camera-relay handshakes.

### Verify locally

```bash
mix phx.server
curl -s localhost:9091/metrics | grep tabletop_prom_ex_game
```

Counters only appear once their event has fired at least once, so a freshly
booted server shows the polled gauges but not yet the event counters.

---

## 2. Traces → Grafana Tempo

Spans are batched and **pushed** over OTLP. Wiring lives in `Tabletop.Tracing`;
spans come from Bandit (HTTP), Phoenix (endpoint, router **and LiveView**
callbacks) and Ecto (one span per query, with the parameterised SQL attached).
No application code emits spans directly.

### Setup

In Grafana Cloud: **Overview → Launch your stack → OpenTelemetry tile →
Configure**. That page generates the endpoint, instance ID and a token together.

```bash
fly secrets set \
  OTEL_EXPORTER_OTLP_ENDPOINT="https://otlp-gateway-prod-us-east-3.grafana.net/otlp" \
  OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64 from Grafana>"
```

Notes:

- Use the **base** URL ending in `/otlp`. The exporter appends `v1/traces`
  itself. Use `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` instead if you need to give a
  complete URL with no suffix appended.
- The region is your **Grafana stack's**, not Fly's — take it from the Configure
  page rather than assuming it matches `iad`.
- Tracing stays off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set. The exporter's
  default target is `http://localhost:4318`, and with nothing listening there
  every batch fails and logs.
- Setting the endpoint **without** credentials raises on boot rather than
  silently exporting nothing.

### Filtered paths

`/health` and `/metrics` produce no traces. Fly polls the health check every 30s
and scrapes metrics every 15s — roughly 8,600 spans a day that carry no
information and are billed like any other.

Filtering is a sampler (`Tabletop.Tracing.PathSampler`) rather than a plug:
`opentelemetry_bandit` has no ignore-path option, and its telemetry handler is
global, so the metrics listener on 9091 emits spans from the same handler as the
main endpoint. The sampler catches both.

It is installed as the `root` of the default `parent_based` sampler, so child
spans still inherit their parent's decision — the Ecto queries inside a dropped
health check disappear with it. Matching is exact, so `/health-history` is still
traced. Edit `:ignore_paths` in `config/config.exs` to change the list.

### Inspect spans locally, without a backend

Temporarily add to `config/dev.exs`:

```elixir
config :opentelemetry, traces_exporter: {:otel_exporter_stdout, []}
```

`mix phx.server` then prints every span. Set
`OTEL_BSP_SCHEDULE_DELAY_MILLIS=200` alongside it — the default 5s batch delay
otherwise makes short-lived runs look as though nothing was produced.

---

## 3. Errors → Sentry

### Setup

```bash
fly secrets set SENTRY_DSN="https://<key>@<org>.ingest.sentry.io/<project>"
```

That is the only variable the *server* needs — the SDK reads `SENTRY_DSN` from
the environment itself, which is why there is no `dsn:` in `config.exs`, and with
no DSN it is disabled outright, so dev and test are silent with no per-env
opt-out. Find it under **Settings → Projects → *project* → Client Keys (DSN)**.

Browser errors go to a **second, separate project** via `SENTRY_FRONTEND_DSN` —
see *Browser errors* below.

### What is wired

- **`Sentry.LoggerHandler`** — reports crashes and `Logger.error` and above.
  Rate limited to 10 events/sec so a crash-looping `GameSession` cannot burn the
  quota.
- **`Sentry.PlugContext`** in the `:browser` pipeline — attaches request
  metadata. There is deliberately **no `Sentry.PlugCapture`**: that is for
  Cowboy, and on Bandit it produces duplicate events.
- **`Sentry.LiveViewHook`** on every application `live_session` — nearly all
  behaviour here lives in LiveView callbacks, so without it an error arrives
  with no URL, user or breadcrumbs. It reads `:peer_data`, `:uri` and
  `:user_agent` from the live socket's `connect_info` in `endpoint.ex`.

The LiveDashboard's own `live_session` is intentionally not hooked — it belongs
to a dependency, and crashes there are still captured by the LoggerHandler.

### Browser errors

`@sentry/browser` reports client-side exceptions into a **separate Sentry
project** from the server, configured with its own DSN:

```bash
fly secrets set SENTRY_FRONTEND_DSN="https://<key>@<org>.ingest.sentry.io/<frontend-project>"
```

Separate because the two have very different noise profiles — an ad-blocker
mangling a request or a wedged browser extension, versus a `GameSession`
crashing. Keeping them apart means each can be triaged, alerted on and
quota-managed without drowning the other. Nothing falls back to `SENTRY_DSN`; an
unset `SENTRY_FRONTEND_DSN` simply means no browser reporting.

Wiring is `assets/js/error_reporting.js`, initialised at the top of `app.js`:

- **Errors only.** Performance tracing and session replay are not imported at
  all, rather than imported and disabled, so esbuild tree-shakes them out. Cost
  as measured: **+29 KB gzipped** (61.6 → 91.0 KB). Adding either integration
  would change that materially.
- **The DSN comes from a `<meta>` tag** rendered by `root.html.heex`, not baked
  in at build time, so one image serves every environment and rotating the DSN
  needs no rebuild. A Sentry DSN is a public identifier — the browser SDK is
  built to ship it in client code. With no DSN the SDK never initialises, so dev
  is silent exactly as the server is.
- **The DSN is sanitised before rendering.** `Layouts.public_dsn/1` truncates
  the userinfo to the public key, because the pre-2016 DSN format embedded a
  secret (`https://public:secret@host/project`) that Sentry still parses. A
  no-op for a modern DSN; the difference between publishing a secret and not for
  a legacy one. The frontend value is held under `:tabletop`, not `:sentry`, so
  the server SDK cannot pick it up and report backend crashes into the frontend
  project.
- **Web Worker errors are forwarded explicitly.** Errors thrown inside a worker
  never reach the main thread's global handler, so the card scanner — the code
  most likely to fail on an unfamiliar camera — would otherwise be invisible.
  `card_scanner/liveview_hook.js` wires both `worker.onerror` (crashed) and the
  worker's own `{type: "error"}` message (caught), tagged `uncaught=true|false`
  to tell a bug from a frame the scanner simply could not read.
- **No CSP change was needed.** `connect-src` already allows `https:` because
  OpenCV.js fetches its wasm from a CDN, and that covers Sentry ingest.

Errors are deliberately the *only* frontend signal. WebRTC quality metrics and
the scanner funnel would need a `pushEvent` → `:telemetry` → PromEx pipeline;
that is a bigger commitment and is not built.

### Node in the Docker build

The builder image has no Node — the asset pipeline otherwise runs entirely on
the standalone esbuild and tailwind binaries. `@sentry/browser` is the first
*runtime* JS dependency, so the Dockerfile now copies Node from
`node:24-trixie-slim` (matching the builder's own Debian release, and the major
in `.tool-versions`) and runs `npm ci --prefix assets --omit=dev` before
`mix assets.deploy`.

`npm ci`, not `npm install`, so the build is reproducible from
`package-lock.json` — which must therefore stay committed. `assets/node_modules`
is both gitignored and dockerignored, so the container always installs fresh for
its own architecture rather than inheriting a host build.

### Verify against the deployed app

```bash
fly ssh console --config infrastructure/fly/fly.toml \
  -C '/app/bin/tabletop rpc "Sentry.capture_message(\"deploy smoke test\")"'
```

Use **`rpc`, not `eval`**. `eval` boots a fresh BEAM with only a minimal set of
applications, so `:sentry` never starts and the call fails with *"the Sentry
configuration seems to be not available … the :sentry application has not been
started yet"*. `rpc` runs on the live node, which is also the config you actually
want to test. (This is why the `Tabletop.Release.*` helpers, which *are* invoked
via `eval`, start their own dependencies first.)

Reading the return value:

| Result | Meaning |
| --- | --- |
| `{:ok, ""}` | Enqueued. The id is empty because the default send is fire-and-forget, not because it failed. |
| `:ignored` | No DSN — Sentry is disabled. |

Pass `result: :sync` to block on delivery and get a real event id back.

Locally, `mix sentry.send_test_event` does the same, but reports Sentry as
disabled unless `SENTRY_DSN` is set in your shell.

---

## 4. Database → Grafana Cloud

Query statistics, live query samples, schema details and explain plans from the
deployed Postgres (`fabtabletop-db`), following
[Grafana's Postgres setup guide](https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/set-up/postgres/postgres/).

### How it works

A Grafana Alloy collector polls Postgres' catalogs and ships the results to
Grafana Cloud — metrics by `remote_write`, everything else as Loki log streams.
Four collectors are enabled in `config.alloy`:

| Collector | Reads | Needs |
| --- | --- | --- |
| `query_details` | `pg_stat_statements` | the extension, `compute_query_id=on` |
| `query_samples` | `pg_stat_activity` joined on `query_id` | `pg_stat_statements.track=all` |
| `schema_details` | table/index/column shape | read access to the tables |
| `explain_plans` | `EXPLAIN` for sampled queries | `track_activity_query_size=4096` |

Those four belong to `database_observability.postgres` and feed the Database
Observability app over Loki. The Prometheus side is separate:
`prometheus.exporter.postgres` has its own `enabled_collectors`, and **that
argument replaces the exporter's defaults rather than adding to them.**

Grafana's setup guide lists only `stat_statements`, which is all the DB
Observability app consumes — but on its own that means no connection counts,
database sizes, cache hit ratios, table/index stats, lock contention or WAL
metrics, which is what community Postgres dashboards query. So `config.alloy`
restates the default set explicitly alongside it. Removing an entry silently
drops those series; there is no "defaults plus" syntax.

A collector that cannot run fails on its own without taking the others down —
on a database without `pg_stat_statements`, `stat_statements` logs
`collector failed` each scrape and the remaining eleven still report.

**The collector runs inside Fly, not from Grafana Cloud.** `fabtabletop-db`
declares `ports = []` and has no public address, so it is reachable only over
Fly's private 6PN network — nothing outside can dial it. Hence a second Fly app
(`fabtabletop-alloy`) on that network. Grafana also asks that Alloy reach the
database host directly rather than through a pooler, which the `.internal` name
does.

Two consequences before copying DSNs out of Grafana's docs:

- **`sslmode=disable`, not `sslmode=require`.** The `postgres:18-alpine` image
  serves no TLS certificate, so `require` simply fails to connect. 6PN traffic is
  already WireGuard-encrypted between machines, so nothing is exposed by this.
- **The DSN is a URL**, so a password containing `@`, `/`, `:` or `+` has to be
  percent-encoded — step 2 below generates an alphanumeric one to sidestep that.
  The role name `db-o11y` contains a hyphen, fine unencoded in a URL but it has
  to stay double-quoted in SQL.

### Setup — step 1: Postgres server settings

Four settings, all start-up flags, already declared on the process command in
`infrastructure/fly/postgres.toml`:

```
shared_preload_libraries=pg_stat_statements
compute_query_id=on
pg_stat_statements.track=all
track_activity_query_size=4096
```

`compute_query_id` is the one that fails quietly. PG18 defaults it to `auto`,
which computes the id only for what `pg_stat_statements` itself asks about,
leaving `pg_stat_activity.query_id` null — and `query_samples` joins on exactly
that column, so it collects nothing while reporting no error.

Deploying applies them, which restarts Postgres (brief downtime for the web app):

```bash
fly deploy --config infrastructure/fly/postgres.toml --ha=false
```

### Setup — step 2: the monitoring role

`fly ssh console -C` does not forward stdin, so run the script over a proxied
connection. In one shell:

```bash
fly proxy 15432:5432 --app fabtabletop-db
```

In another, from the repo root:

```bash
# Alphanumeric on purpose — it goes straight into the DSN in step 3.
DB_O11Y_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
echo "$DB_O11Y_PASSWORD"

PGPASSWORD='<the fabtabletop superuser password>' \
  psql -h 127.0.0.1 -p 15432 -U fabtabletop -d fabtabletop \
       -v db_o11y_password="$DB_O11Y_PASSWORD" \
       -f infrastructure/monitoring/db-o11y-setup.sql
```

The script prints a verification table at the end — all six rows should read
`ok`. If `shared_preload_libraries` reads `MISSING`, step 1 did not take effect.

It grants `pg_monitor`, `pg_read_all_stats` and `pg_read_all_data`. That last one
departs from Grafana's docs, which suggest per-schema `GRANT SELECT ON ALL
TABLES` — but that only covers tables existing at grant time, so every later
migration would add one `schema_details` and `explain_plans` silently could not
see. `pg_read_all_data` (PG14+) is a standing read-only grant that cannot drift.

The script is idempotent, so re-running it is also how you rotate the password or
repair the grants.

### Setup — step 3: deploy the collector

From the **repo root** — as with the other Fly apps here, the build context is
the working directory while `build.dockerfile` resolves against the config file,
so the `COPY` of `config.alloy` only works from the root.

```bash
fly launch --config infrastructure/monitoring/alloy.toml --no-deploy

fly secrets set --app fabtabletop-alloy \
  PG_DSN="postgresql://db-o11y:$DB_O11Y_PASSWORD@fabtabletop-db.internal:5432/fabtabletop?sslmode=disable" \
  GCLOUD_RW_API_KEY="<grafana-cloud-access-policy-token>" \
  GCLOUD_HOSTED_METRICS_URL="https://prometheus-<region>.grafana.net/api/prom/push" \
  GCLOUD_HOSTED_METRICS_ID="<prometheus-instance-id>" \
  GCLOUD_HOSTED_LOGS_URL="https://logs-<region>.grafana.net/loki/api/v1/push" \
  GCLOUD_HOSTED_LOGS_ID="<loki-instance-id>"

fly deploy --config infrastructure/monitoring/alloy.toml --ha=false
fly scale count 1 --app fabtabletop-alloy
```

The `GCLOUD_HOSTED_*` values come from the Prometheus and Loki pages under
**Connections → Data sources** in your Grafana Cloud stack; the API key is an
access policy token with `metrics:write` and `logs:write`. That is the same
access policy as § 2's Tempo token — one policy can carry all three scopes.

**The two instance IDs are different numbers.** Each service in the stack has its
own numeric username — Prometheus, Loki and Tempo all differ, and § 2's OTLP
gateway id is a fourth. They are on separate pages, so if you are hunting for
both on one screen you will not find them. The *token*, by contrast, is
deliberately shared: one access policy token is the password for both endpoints.

Rotating the database password means re-running step 2 and then updating `PG_DSN`
with `fly secrets set`, which restarts the collector.

### Verify

```bash
fly logs --app fabtabletop-alloy          # quiet is healthy; no auth or dial errors
fly proxy 12345 -a fabtabletop-alloy      # then http://localhost:12345 for Alloy's UI
```

The database appears under **Observability → Databases** within a few minutes.
Query statistics need traffic to accumulate, so a freshly created
`pg_stat_statements` looks empty until the app has served some requests.

The collectors log on failure, not on success, so a quiet log is the healthy
state. One benign line appears at start-up —
`no tables detected from pg_tables datname=postgres` — which is just the empty
`postgres` maintenance database being enumerated alongside `fabtabletop`.

Measured against a single Postgres target, Alloy sits at ~58 MB RSS and ~0.3% of
one shared CPU, which is why the machine is only sized at 256 MB.

The whole pipeline can also be verified **without Grafana Cloud credentials**:
point `PG_DSN` at any Postgres, leave the `GCLOUD_*` values as dummies, and read
Alloy's own metrics from `http://localhost:12345/metrics`. A non-zero
`prometheus_remote_storage_samples_total` proves the database is being scraped,
and a non-zero `loki_write_batch_retries_total` proves the collectors are
producing entries. Both then fail to *ship*, which is the only part bad
credentials break.

### There is no local setup

The dev database in `docker-compose.yml` runs stock Postgres with no extra flags,
so `pg_stat_statements` is unavailable locally and none of the above applies —
`db-o11y-setup.sql` would fail its own verification on the first row. This signal
is production-only; use the credential-free check above against the deployed
database if you need to exercise the pipeline.

That is also why `CREATE EXTENSION pg_stat_statements` is a documented one-liner
for the deployed database rather than an Ecto migration: neither the dev Postgres
nor CI's preloads the module, and the statement errors out when it was not
preloaded, so a migration would fail on both.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Grafana data source: **403** `not authorized for org` | App-scoped Fly token. Use `fly tokens create readonly`. |
| Grafana data source: **401** `something went wrong resolving organization` | Wrong auth scheme or org slug. Needs `FlyV1 `, not `Bearer `. |
| Tempo: **401** `authentication error: no credentials provided` | Percent-encoded OTLP header — see below. |
| Traces work locally, almost none reach Tempo | `:inets` missing from `extra_applications` — see below. |
| Sentry: *"the :sentry application has not been started yet"* | Used `eval` instead of `rpc`. |
| Metrics gauges gap, counters reset | A deploy. Metrics are in-memory and per-machine. |
| Alloy: `SSL is not enabled on the server` | DSN says `sslmode=require`. The Postgres image serves no certificate; use `sslmode=disable` over 6PN. |
| Alloy: **401** `authentication error: invalid token` on **both** exporters | `GCLOUD_RW_API_KEY` — see below. Failing on both at once rules out the instance ids. |
| Database appears, but query panels stay empty | `job` label missing from the Loki path — see below. |
| Database panels populate, but **Query samples** stays empty | `compute_query_id` is `auto`, not `on`. `pg_stat_activity.query_id` is null so the join finds nothing — and nothing errors. |
| Explain plans truncated or missing | `track_activity_query_size` still at its 1024 default. |
| Ecto Stats has no **Calls**/**Outliers** tab | `CREATE EXTENSION pg_stat_statements` was never run on that database. Expected in dev, which runs stock Postgres. |
| `CREATE EXTENSION` fails: *must be loaded via shared_preload_libraries* | Preload flag not applied yet — deploy `postgres.toml` first. |

### Alloy `401 invalid token`

Read *how many* exporters are failing before touching anything:

```
prometheus.remote_write → prometheus-prod-NN-… → 401 "invalid token"
loki.write              → logs-prod-NNN…       → 401 "invalid token"
```

Both failing at once is the diagnosis. The two endpoints use *different*
instance ids and share only `GCLOUD_RW_API_KEY`, so the shared key is the
variable at fault — no point re-checking the ids. Only one failing would mean the
opposite: that endpoint's id or URL.

Note the wording. `invalid token` means Grafana does not recognise the
credential at all; a *recognised* token missing a scope returns **403**. So this
is a wrong, mistyped or revoked token rather than a permissions problem. The most
common cause is token type — Cloud Access Policy tokens begin `glc_`, while a
Grafana service-account token (`glsa_`) or stack API key looks similar and is
accepted nowhere in Cloud ingestion.

Isolate it without redeploying:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
  -u "<GCLOUD_HOSTED_METRICS_ID>:<GCLOUD_RW_API_KEY>" \
  "$GCLOUD_HOSTED_METRICS_URL"
```

`401` means the token is bad. `400` means authentication **succeeded** and the
server is merely rejecting the empty body — so the credential is fine and the
problem is elsewhere.

### The `job` label is load-bearing for logs

`config.alloy` sets `job = "integrations/db-o11y"` on *both* paths —
`discovery.relabel` for metrics and `loki.relabel` for logs. Grafana Cloud's
Database Observability app keys off that exact value to attach telemetry to an
instance; it is a required identifier, not a naming convention.

`database_observability.postgres` does **not** label the logs it forwards, so the
`loki.relabel` block has to add both `job` and `instance` itself. Drop `job` and
the logs still arrive in Loki, but `query_details`, `query_samples`,
`schema_details` and `explain_plans` never bind to the database — the instance
shows up with metrics and permanently empty query panels, which reads as a
collector problem rather than a labelling one.

### The OTLP `%20` trap

Grafana's generated snippet reads
`OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic%20<base64>`. The exporter re-reads
that variable from the OS environment and `otel_configuration` ranks OS env
**above** app env, so it wins over anything `runtime.exs` computes. Its parser
splits on `=` and strips quotes but never percent-decodes — so the header ships
as `Basic%20<base64>`: no space, therefore no recognisable auth scheme, therefore
"no credentials provided".

`runtime.exs` normalises the variable in place before any application starts, so
the pasted snippet works as-is. On an older build, set it with a **real space**:

```bash
fly secrets set OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic <base64>"
```

The same OS-over-app-env precedence applies to every `OTEL_*` variable — prefer
setting those directly over adding app config that would be silently overridden.

### `:inets` is load-bearing for tracing

`:inets` and `:ssl` must stay in `extra_applications` in `mix.exs`. The OTLP
exporter uses `httpc`, which they provide; without them a release boots with:

```
[warning] OTLP exporter failed to initialize with exception :error:{:badmatch, {:error, :inets_not_started}}
...
[info] OTLP exporter successfully initialized     # ~5 seconds later
```

It recovers, but **every span produced in that window is discarded**, so the
first few seconds after each deploy are untraced. This was far worse under
scale-to-zero, where the machine cold-started for every burst of traffic and most
requests fell inside the window — the symptom being "tracing works locally but
almost nothing reaches Tempo".

---

## Caveats worth knowing

**Metrics are per-machine and in-memory.** They do not survive a restart: a
deploy resets every counter and gaps the gauges. Use `rate()`/`increase()`, which
account for counter resets, and read a gap as "deployed", not as zero. The
machine stays up (`auto_stop_machines = 'off'`, `min_machines_running = 1`), so
the series are otherwise continuous.

**Spans buffered when the VM stops are lost.** With the machine always on that
means a deploy. `OTEL_BSP_SCHEDULE_DELAY_MILLIS` controls how large that window
is; the default is 5s.

**Tracing is Grafana's, not Sentry's.** Sentry's Elixir tracing is still beta and
installs its own OTel span processor *and sampler* — the latter would collide
with `PathSampler`, so enabling it means moving the `/health` and `/metrics`
filtering into Sentry's `traces_sampler`.

**Two tokens are the floor.** Fly's Prometheus needs a Fly token; Grafana Cloud
needs a Grafana token. Different issuers, so no single credential spans both. One
Grafana Cloud access policy can carry `traces:write` + `logs:write` +
`metrics:write`, so the count stays at two even if you add logs later — and the
database collector reuses that same policy rather than adding a third.

**The four Postgres flags are start-up flags.** `shared_preload_libraries`,
`compute_query_id`, `pg_stat_statements.track` and `track_activity_query_size`
cannot be set at runtime, which is why they live on the process command in
`infrastructure/fly/postgres.toml` rather than in an `ALTER SYSTEM` on the volume
— a rebuilt volume then comes back with them intact. Dropping any of them
degrades § 4 silently, never loudly.

**Database observability has no local equivalent.** Metrics, traces and errors
can all be exercised on a dev machine (`localhost:9091`, the stdout span
exporter, `mix sentry.send_test_event`). The dev Postgres deliberately runs stock,
without the flags § 4 needs, so there is nothing to point a collector at — the
credential-free check in § 4 is as far as local verification goes.
