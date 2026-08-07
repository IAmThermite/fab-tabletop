# Monitoring & Observability

Setup guide for the three signals this app emits, and the provider-side
configuration each one needs.

| Signal | Emitted by | Stored in | Answers |
| --- | --- | --- | --- |
| **Metrics** | PromEx → `/metrics` on :9091 | Fly's managed Prometheus | "Is it healthy? What are the rates?" |
| **Traces** | OpenTelemetry → OTLP push | Grafana Cloud Tempo | "Why was *this* request slow?" |
| **Errors** | Sentry SDK | Sentry | "What broke, is it new, how often?" |

They overlap less than they appear. Metrics catch **working-but-wrong** — a card
that fails to scan raises no exception, so only the scanner hit-rate metric will
ever tell you the pHash thresholds have drifted. Sentry catches **crashed** and,
unlike Tempo, groups and dedupes them into issues with "this is new since the
last release". Tempo records exceptions too, but has no issue model, so you have
to already suspect a problem to go looking for it.

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

That is the only variable needed. The SDK reads `SENTRY_DSN` from the
environment itself, which is why there is no `dsn:` in `config.exs` — and with no
DSN the SDK is disabled outright, so dev and test are silent with no per-env
opt-out. Find it under **Settings → Projects → *project* → Client Keys (DSN)**.

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

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Grafana data source: **403** `not authorized for org` | App-scoped Fly token. Use `fly tokens create readonly`. |
| Grafana data source: **401** `something went wrong resolving organization` | Wrong auth scheme or org slug. Needs `FlyV1 `, not `Bearer `. |
| Tempo: **401** `authentication error: no credentials provided` | Percent-encoded OTLP header — see below. |
| Traces work locally, almost none reach Tempo | `:inets` missing from `extra_applications` — see below. |
| Sentry: *"the :sentry application has not been started yet"* | Used `eval` instead of `rpc`. |
| Metrics gauges gap, counters reset | A deploy. Metrics are in-memory and per-machine. |

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
`metrics:write`, so the count stays at two even if you add logs later.
