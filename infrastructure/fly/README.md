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

### 3. Create the TURN server app

WebRTC needs a TURN relay for users behind symmetric NATs (most cellular networks).
coturn runs as its own Fly app and authenticates clients with time-limited HMAC
credentials minted by the web app (`Tabletop.Turn`), using a shared secret.

> For *why* any of this is shaped the way it is — ICE candidate types, why STUN
> fails on symmetric NAT, the credential handshake, and what every coturn setting
> does — see [`infrastructure/coturn/README.md`](../coturn/README.md). The steps
> below are just the deployment mechanics.

Work through these in order and stop at each **gate** — every one of them
isolates a different layer, so a failure tells you where the problem is.

**Keep one shell open for the whole run.** `$TURN_SECRET` is generated in step
3.2 and reused verbatim in 3.4; if the two apps end up with different values,
every allocation fails with `401` and there is no other symptom.

#### 3.1 Create the app and claim a dedicated IPv4

```bash
cd <repo root>

# Use `apps create`, NOT `fly launch` — launch runs a source scanner that
# rewrites fly.toml (it would add an [http_service] block and drop the
# hand-written UDP and relay-range services).
fly apps create fabtabletop-turn

# TURN must own a stable public IP and hand it out as the relay address, so
# allocate a DEDICATED IPv4 — a shared Anycast v4 cannot work, because the
# opponent has to reach this exact machine. ~$2/mo.
fly ips allocate-v4 --app fabtabletop-turn

# Read the address back; you need it three more times below.
fly ips list --app fabtabletop-turn
```

#### 3.2 Set secrets *before* the first deploy

`EXTERNAL_IP` is mandatory: on Fly the dedicated v4 lives on the edge proxy and
is invisible inside the container, so coturn cannot discover it and
`entrypoint.sh` refuses to boot without it. Deploying first just gives you a
crash-looping machine.

```bash
TURN_SECRET=$(openssl rand -hex 32)

fly secrets set \
  TURN_SECRET="$TURN_SECRET" \
  EXTERNAL_IP="<turn-ipv4>" \
  --app fabtabletop-turn
```

#### 3.3 Deploy coturn

Run from the **repo root**: the build context is the working directory, and
`infrastructure/coturn/Dockerfile` COPYs root-relative paths.

```bash
fly deploy --config infrastructure/coturn/fly.toml
```

If the build fails with "Dockerfile not found", flyctl is resolving
`build.dockerfile` against the working directory rather than against the config
file — change that line in `infrastructure/coturn/fly.toml` to
`dockerfile = 'infrastructure/coturn/Dockerfile'`.

##### Gate A — did coturn come up?

```bash
fly status --app fabtabletop-turn    # expect 1 machine, started
fly logs --app fabtabletop-turn
```

Look for the coturn 4.12 banner, and confirm there is **no** `FATAL:` line and
**no** `Bad configuration format` line (the latter means an option name this
coturn version doesn't recognise — it is ignored silently, so it never fails the
boot).

One warning here is expected and correct until you do step 3.5:
`TURN_TLS_CERT/TURN_TLS_KEY unset — turns: (TLS) disabled`.

#### 3.4 Point the web app at it

```bash
fly secrets set \
  TURN_SECRET="$TURN_SECRET" \
  TURN_URLS="turn:<turn-ipv4>:3478" \
  --app fabtabletop
```

Setting secrets restarts the machines, and `runtime.exs` re-reads both on boot.

##### Gate B — does it actually relay?

This is the gate that matters, and it involves no Phoenix, no game and no
browser permissions — so a failure here is definitely coturn or the network path
to it.

Mint a credential without booting the app. This reproduces exactly what
`Tabletop.Turn` computes (verified byte-for-byte against it):

```bash
SECRET="<the TURN_SECRET>"
USERNAME="$(( $(date +%s) + 3600 )):test"
CREDENTIAL=$(printf '%s' "$USERNAME" | openssl dgst -sha1 -hmac "$SECRET" -binary | base64)
echo "username:   $USERNAME"
echo "credential: $CREDENTIAL"
```

Put `turn:<turn-ipv4>:3478` plus that pair into the
[Trickle ICE tester](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)
and look for a row of type **`relay`**. If you only see `host`/`srflx`, TURN
isn't reachable.

**Do this from a mobile network, not your home wifi.** Home NAT is usually
permissive enough that `srflx` succeeds on its own, so a test from your desk
passes whether or not TURN works — you would be validating nothing. Cellular
symmetric NAT is the case TURN exists for, and Fly's UDP proxying is the least
battle-tested part of this whole setup.

When it fails, `fly logs --app fabtabletop-turn` distinguishes the causes: a
wall of `401` means the two `TURN_SECRET` values differ; `allocation quota
reached` means the port range is too small; **nothing at all** means the Allocate
request never arrived, so the problem is the network path rather than the auth.

##### Gate C — a real game

Two players, ideally one of them on cellular. Open `chrome://webrtc-internals`,
find the nominated candidate pair, and confirm `relay` appears when you would
expect it. This is also how you measure what fraction of real games need the
relay at all — the number that tells you whether to widen the port range.

#### 3.5 TLS (`turns:` on 443) — optional, needs a domain

Skip this if you just want to get playing; plain TURN already covers the
cellular case. Add it when you want the corporate/guest-wifi case too.

Plain TURN on 3478 covers symmetric NAT. It does **not** cover corporate and
guest wifi, which routinely drop 3478 and 5349 and permit only 443 — and those
are exactly the networks where a relay is the only thing that works.

**coturn does not handle the certificate.** `infrastructure/coturn/fly.toml`
gives port 443 the Fly `tls` handler, so Fly's edge terminates TLS and forwards
the decrypted stream to the same plain TURN listener on 3478 that serves port
3478. Fly issues and **auto-renews** the cert, so there is no rotation to do:

```bash
# 1. Point a hostname at the dedicated IPv4 (A record):
#      turn.yourdomain.com -> <turn-ipv4>

# 2. Have Fly issue and manage the cert for it.
fly certs add turn.yourdomain.com --app fabtabletop-turn
fly certs show turn.yourdomain.com --app fabtabletop-turn   # wait for "Ready"

# 3. Set the realm to match the hostname.
fly secrets set TURN_REALM="turn.yourdomain.com" --app fabtabletop-turn

# 4. Advertise both arms to clients. The turns: URL must use the hostname the
#    cert was issued for — an IP will fail certificate validation.
fly secrets set \
  TURN_URLS="turn:<turn-ipv4>:3478,turns:turn.yourdomain.com:443?transport=tcp" \
  --app fabtabletop
```

Until a cert is issued, coturn boots with `--no-tls --no-dtls` and logs a
warning; plain TURN still works and only the strict-firewall case is lost.

Re-run **Gate B** against the `turns:` URL afterwards. If a `relay` candidate
appears on `turn:` but never on `turns:`, that points at the Fly `tls` handler
specifically — take the fallback below.

**Fallback — coturn terminating TLS itself.** Fly's `tls` handler for raw TCP
is the least-exercised part of this setup. If a `turns:` candidate never
appears once the cert is Ready, drop `handlers = ['tls']` from the 443 port,
change that port's `internal_port` to 443, and hand coturn the cert directly as
base64 PEM secrets — `entrypoint.sh` already supports this and will enable its
own TLS listener on 443:

```bash
certbot certonly --manual --preferred-challenges dns -d turn.yourdomain.com
fly secrets set \
  TURN_TLS_CERT="$(base64 -w0 < /etc/letsencrypt/live/turn.yourdomain.com/fullchain.pem)" \
  TURN_TLS_KEY="$(base64 -w0 < /etc/letsencrypt/live/turn.yourdomain.com/privkey.pem)" \
  --app fabtabletop-turn
```

That path costs you a manual re-run every 90 days, which is exactly what the
Fly-managed cert avoids. Only take it if the handler genuinely doesn't work.

#### Reference — scaling out

TURN does **not** scale by adding machines to this app. An allocation lives on
one specific machine and the client must keep reaching that same machine for
the life of the call; several machines behind one Fly Anycast IP would spray a
client's packets across them and break allocations. `min_machines_running = 1`
with `auto_stop_machines = 'off'` is deliberate — scale this app *up*, never
*out*.

Capacity order of operations:

1. **Widen the relay range.** `min-port`/`max-port` in `turnserver.conf`, the
   matching `start_port`/`end_port` in `fly.toml`, and `total-quota` all move
   together — one UDP relay port per allocation is the hard cap.
2. **Grow the VM.** coturn is packet-forwarding, so bandwidth binds long before
   CPU does; `shared-cpu-2x` covers a lot of concurrent relays.
3. **Only then add a second TURN app** — `fabtabletop-turn-<region>`, its own
   dedicated IPv4, its own `EXTERNAL_IP`, its own hostname and
   `fly certs add`. Append it to `TURN_URLS`. Cert management stays automatic
   per app; there is just one `fly certs add` per server.

Note that every URL in `TURN_URLS` makes each client allocate on *every* listed
server during ICE gathering. Two servers means two allocations per client, not
half the load each — it buys redundancy and lets ICE race for the lowest
latency, but for pure capacity you want `Tabletop.Turn` to hand each user one
server (e.g. keyed on `user_id`) instead.

#### Reference — port ranges

The relay UDP range (`49160-49259`) is declared in both
`infrastructure/coturn/turnserver.conf` (`min-port`/`max-port`) and
`infrastructure/coturn/fly.toml` (a single `start_port`/`end_port` range). Keep
them in sync — Fly only routes ports it knows about.

Budget one port per allocation: a relayed player costs one, and the
phone-as-camera flow is a second peer connection, so a fully-relayed game with
both players on phones costs 4. 100 ports is comfortable headroom for a beta.

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

## Query statistics (pg_stat_statements)

The LiveDashboard "Ecto Stats" page (`/dev/dashboard/ecto_stats`) gets two extra
tabs — **Calls** and **Outliers**, the slow-query analysis — when the
`pg_stat_statements` extension is active. `ecto_psql_extras` probes for it and
silently omits those tabs when it is missing, so this is optional.

It takes two steps, because the module allocates shared memory at server start:

```bash
# 1. Preload the module. Already declared in postgres.toml; this applies it and
#    restarts Postgres (brief downtime for the web app).
fly deploy --config infrastructure/fly/postgres.toml

# 2. Create the extension in the app database (one-off, persists in the volume)
fly ssh console --app fabtabletop-db \
  -C "psql -U fabtabletop -d fabtabletop -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'"
```

Verify:

```bash
fly ssh console --app fabtabletop-db \
  -C "psql -U fabtabletop -d fabtabletop -tAc 'show shared_preload_libraries'"
# => pg_stat_statements
```

Step 1 is required before step 2 — `CREATE EXTENSION` fails with
"pg_stat_statements must be loaded via shared_preload_libraries" otherwise.

The same extension backs Grafana Cloud database observability, which adds three
more server settings to `postgres.toml` and a read-only monitoring role — see
[../monitoring/README.md](../monitoring/README.md) § 4.

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

## Error tracking (Sentry)

Enable it by setting the DSN; the SDK reads `SENTRY_DSN` from the environment
itself, and with no DSN it is disabled outright, which is why dev and test need
no opt-out:

```bash
fly secrets set SENTRY_DSN="https://<key>@<org>.ingest.sentry.io/<project>"
```

Verify the config end to end with:

```bash
mix sentry.send_test_event
```

## Tracing (Grafana Tempo)

Traces are batched and **pushed** over OTLP rather than scraped. Wiring lives in
`Tabletop.Tracing`; spans come from Bandit (HTTP), Phoenix (endpoint, router
**and LiveView** callbacks) and Ecto (one span per query, with the parameterised
SQL attached).

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

### Caveat: metrics are per-machine and in-memory

`fly.toml` sets `auto_stop_machines = 'off'` with `min_machines_running = 1`, so
the machine stays up and the series are continuous during normal operation.

They are still **not** durable across a restart: metrics live in the machine's
memory, so a deploy resets every counter and leaves a gap in the gauges. Use
`rate()`/`increase()` in queries — they account for counter resets — and read a
gap as "deployed", not as zero.

## Environment

- **PHX_HOST**: Set in fly.toml — update this after adding a custom domain
- **DATABASE_URL**: Set via `fly secrets set`, uses Fly private DNS (`.internal`, IPv6)
- **ECTO_IPV6**: Set in fly.toml — required because `.internal` DNS resolves to IPv6
- **SECRET_KEY_BASE**: Set via `fly secrets set`
- **TURN_SECRET**: Shared HMAC secret for TURN auth — must be identical on the web app and the `fabtabletop-turn` app. If unset, clients fall back to STUN-only.
- **TURN_URLS**: Comma-separated `turn:`/`turns:` URLs on the web app (e.g. `turn:<turn-ipv4>:3478,turns:turn.yourdomain.com:443?transport=tcp`).
- **EXTERNAL_IP** (`fabtabletop-turn`): **Required.** The dedicated IPv4 coturn advertises as the relay address. Not auto-detectable on Fly; the entrypoint exits if it's missing.
- **TURN_REALM** (`fabtabletop-turn`): Optional; defaults to `fabtabletop.fly.dev`. Set it to the TLS hostname once you have one.
- **TURN_TLS_CERT** / **TURN_TLS_KEY** (`fabtabletop-turn`): Optional base64 PEM pair. Present ⇒ `turns:` on 443; absent ⇒ TLS disabled with a warning.
- **MAILERSEND_API_KEY** / **MAILER_FROM_EMAIL**: Required for registration-confirmation emails — the app raises on boot if `MAILER_FROM_EMAIL` is unset.
- **METRICS_PORT**: Optional, defaults to `9091` — must match `[metrics]` in fly.toml
