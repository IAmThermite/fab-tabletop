# Fly.io Deployment

## Prerequisites

- [flyctl](https://fly.io/docs/flyctl/install/) installed
- Fly.io account (`fly auth signup`)

## Initial Setup

### One machine per app

**All three apps in this deployment run exactly one machine, and `fly deploy`
does not default to that.** Given an app with services and no machines yet, it
creates *two*. There is no fly.toml key that forbids it — `min_machines_running`
is the floor the autostop reaper respects, not a cap — so `--ha=false` on the
first deploy of an app is the whole enforcement mechanism. It is a harmless no-op
once a machine exists, so keep it on the command line rather than remembering
when it matters.

None of the three apps is *wrong* in the ordinary "wasted money" way with two
machines; each breaks differently, and none of them loudly:

| App | What a second machine does |
| --- | --- |
| `fabtabletop` | Splits every game. The BEAM nodes are **not clustered** — `DNS_CLUSTER_QUERY` is unset, so `DNSCluster` starts as `:ignore`. `Tabletop.Games.GameSessionRegistry` is a node-local `Registry`, so two players routed to different machines each get their own `GameSession` GenServer for the same `game_id`, with their own life totals and combat chain. `Phoenix.PubSub` and the `:pg` group behind the camera relay don't cross either. Both players see a working page and neither sees the other's actions. |
| `fabtabletop-db` | Two Postgres machines, each with its own volume — Fly does not replicate one. The second boots an *empty* database, and which one you reach depends on 6PN DNS ordering. |
| `fabtabletop-turn` | Breaks TURN allocations — an allocation is a socket on one machine and the dedicated IPv4 is Anycast. Details in [3.4](#34-deploy-coturn) and "Reference — scaling out". |

If an app already has two, drop back to one with
`fly scale count 1 --app <name>`. For `fabtabletop-db` check *which* machine has
the real volume before removing either.

**Setting `DNS_CLUSTER_QUERY` is not the fix for the `fabtabletop` row**, though
it is the obvious first guess. Clustering the BEAM nodes would repair the
*transport* — `Phoenix.PubSub`'s PG2 adapter and the `:pg` scope behind
`TabletopWeb.ChannelSeat` both become cluster-wide — but `GameSession` registers
through a node-local `Registry` under a node-local `DynamicSupervisor`, and
clustering does not change that. Two sessions per game would still exist; they
would now both broadcast onto `game_session:<game_id>`, so every LiveView
receives both and the state flaps between two divergent snapshots instead of
splitting cleanly. That is a *worse* failure to debug. `LeaveTimerRegistry` and
`GameConnectionRegistry` are node-local for the same reason, so the leave timer
would also fire on users connected via the other machine.

Supporting a second web machine means, in order: a cluster-wide registry for
`GameSession` (`:global` via-tuple or Horde — there is no clustering dependency
in `mix.exs` today) and the same for the other two registries, *then*
`DNS_CLUSTER_QUERY`. The cheaper route is `fly-replay` sticky routing on
`game_id` so both players of a game always land on one machine. Neither is worth
doing pre-emptively: the media is peer-to-peer, so the server only brokers
signalling and small in-memory state, and scaling the VM up goes a long way
first.

### 1. Create the Postgres database app

```bash
# Create the database app
fly launch --config infrastructure/fly/postgres.toml --no-deploy

# Create a 1GB persistent volume for data
fly volumes create pg_data --size 1 --region iad --app fabtabletop-db

# Set the Postgres password
fly secrets set POSTGRES_PASSWORD=<your-secure-password> --app fabtabletop-db

# Deploy Postgres — --ha=false, see "One machine per app" above
fly deploy --config infrastructure/fly/postgres.toml --ha=false
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
fly deploy --config infrastructure/fly/fly.toml --ha=false
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
3.3 and reused verbatim in 3.5; if the two apps end up with different values,
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

# Read the address back; you need it several more times below.
fly ips list --app fabtabletop-turn
```

**Do not allocate an IPv6.** Fly cannot proxy UDP over IPv6 at all, so a v6
address on this app is not a second way in — it is only a way for a client to
pick an address that silently cannot carry media. Plain `fly ips allocate-v4`
and nothing else.

#### 3.2 DNS — point a hostname at the address

Strictly optional for plain TURN (you can put the raw IPv4 in `TURN_URLS`), but
do it now anyway: it is **required** for the `turns:` arm in 3.6, because a TLS
certificate cannot be issued for an IP literal, and it means a future IP change
is a DNS edit rather than a redeploy of the web app.

`fabtabletop.net` is on Cloudflare, so create the record there:

| Field | Value |
| --- | --- |
| Type | `A` |
| Name | `turn` |
| IPv4 address | the dedicated v4 from 3.1 |
| Proxy status | **DNS only (grey cloud)** |
| TTL | Auto |

Two things about that table are load-bearing, and both fail silently:

- **Proxy status must be DNS only.** The apex `fabtabletop.net` is proxied
  (orange cloud) and should stay that way, but Cloudflare's proxy does not
  forward UDP, and it terminates the TCP ports it does forward. An orange-clouded
  `turn` record hides the dedicated IPv4 behind Cloudflare's anycast edge, and
  every allocation fails — including the TCP and 443 arms. Grey cloud publishes
  the real address, which is the entire point of paying for a dedicated one.
- **Do not add an AAAA record.** Fly cannot route UDP over IPv6. If the hostname
  resolves to both families, a dual-stack browser will happily try the v6
  address, gather nothing, and you get an intermittent failure that correlates
  with the client's network rather than with anything on the server.

Confirm before moving on — the answer must be the dedicated IPv4, and the AAAA
lookup must be empty:

```bash
dig +short A    turn.fabtabletop.net    # => <turn-ipv4>
dig +short AAAA turn.fabtabletop.net    # => (nothing)
```

If the A lookup returns a `104.21.*` or `172.67.*` address, the record is still
proxied.

#### 3.3 Set secrets *before* the first deploy

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

That is the whole list. The *internal* address coturn relays from is resolved at
boot from `fly-global-services` — see the reference at the end of this section
for what the entrypoint computes and why.

#### 3.4 Deploy coturn

Run from the **repo root**. `build.dockerfile` in a fly.toml is resolved relative
to the config file, so `dockerfile = 'Dockerfile'` finds
`infrastructure/coturn/Dockerfile`; the build *context* is the working directory,
which is why that Dockerfile's `COPY infrastructure/coturn/...` paths are
repo-root-relative. (The web app's config relies on the same rule from the other
direction: `dockerfile = '../Dockerfile'` in `infrastructure/fly/fly.toml`
resolves to `infrastructure/Dockerfile`.)

```bash
fly deploy --config infrastructure/coturn/fly.toml --ha=false
```

**`--ha=false` is not optional here.** When `fly deploy` finds an app with
services and zero machines it creates *two*, for high availability. That is the
wrong shape for this app, for the reason in "Reference — scaling out" below: a
TURN allocation lives on one specific machine, and the dedicated IPv4 is Anycast,
so a client's packets get sprayed across both machines and allocations break.
There is no fly.toml key for machine count — `min_machines_running` is the
autostop floor, not a cap — so this flag is the only thing standing between you
and a two-machine deploy. Pass it on every `fly deploy` for this app; it is a
no-op once one machine exists, and load-bearing on the day the app gets rebuilt
from scratch.

If you already have two, drop back to one (either machine — they are
interchangeable, coturn holds no state):

```bash
fly scale count 1 --app fabtabletop-turn
```

##### Gate A — did coturn come up?

```bash
fly status --app fabtabletop-turn    # expect exactly 1 machine, STATE=started
fly logs --app fabtabletop-turn
```

Check the machine *count* here, not just the state — two started machines look
healthy in every other check and fail only under real relay traffic, and
intermittently, since whether a given call breaks depends on which machine the
Anycast IP happened to land its packets on.

A machine in `STATE=stopped` is TURN being **down**, not idle: this app sets
`auto_start_machines = false`, so nothing restarts it — not incoming traffic,
not a health check. Fly only starts a stopped machine on demand for services it
can hold a connection open for while booting, and TURN's traffic is UDP.
Whatever stopped it (a manual `fly machine stop`, a host migration, an OOM), it
stays stopped until you run `fly machine start <id> --app fabtabletop-turn`.
The failure is silent from the app's side — `Tabletop.Turn` still mints
credentials and every client still gets its `iceServers` list, so calls just
quietly fall back to STUN-only and fail on exactly the cellular and corporate
networks TURN exists for. Nothing alerts on this; re-check it after any manual
machine operation.

Four lines to look for, and one to make sure is absent:

```
coturn: relaying on 172.19.x.x, advertised as <turn-ipv4>
INFO Relay address to use: 172.19.x.x          <- exactly one, and it is IPv4
INFO Whitelisting external-ip private part: 172.19.x.x
INFO Coturn Version Coturn-4.17.2 'Gorst'
```

- **No `FATAL:` line.** The entrypoint refuses to boot on a missing
  `TURN_SECRET`, a missing `EXTERNAL_IP`, or an unresolvable
  `fly-global-services`, and says which.
- **No `Bad configuration format` line.** That means an option name this coturn
  version no longer recognises. coturn logs it and then boots anyway, so it
  never fails the deploy — it just quietly drops the setting. This is why the
  image is pinned; re-read this log whenever you bump it.
- **Exactly one `Relay address to use`, and it is the IPv4.** If you see a second
  one — an `fdaa::` or `::1` — the relay pinning is not being applied and
  allocations will be handed out on an address Fly cannot route.

`INFO: TURN_TLS_CERT/TURN_TLS_KEY unset — coturn is not terminating TLS` is
expected and correct; Fly terminates TLS at the edge (3.6).

#### 3.5 Point the web app at it

```bash
fly secrets set \
  TURN_SECRET="$TURN_SECRET" \
  TURN_URLS="turn:turn.fabtabletop.net:3478" \
  --app fabtabletop
```

Setting secrets restarts the machines, and `runtime.exs` re-reads both on boot.
Use the raw IPv4 instead of the hostname if you skipped 3.2.

##### Gate B — does it actually relay?

This is the gate that matters, and it involves no Phoenix, no game and no
browser permissions — so a failure here is definitely coturn or the network path
to it.

Mint a credential without booting the app. This reproduces exactly what
`Tabletop.Turn` computes, including the expiry quantisation:

```bash
SECRET="<the TURN_SECRET>"
WINDOW=3600; TTL=28800
USERNAME="$(( ( $(date +%s) / WINDOW + 1 ) * WINDOW + TTL )):test"
CREDENTIAL=$(printf '%s' "$USERNAME" | openssl dgst -sha1 -hmac "$SECRET" -binary | base64)
echo "username:   $USERNAME"
echo "credential: $CREDENTIAL"
```

Put `turn:turn.fabtabletop.net:3478` plus that pair into the
[Trickle ICE tester](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)
and look for a row of type **`relay`**. If you only see `host`/`srflx`, TURN
isn't reachable.

**Do this from a mobile network, not your home wifi.** Home NAT is usually
permissive enough that `srflx` succeeds on its own, so a test from your desk
passes whether or not TURN works — you would be validating nothing. Cellular
symmetric NAT is the case TURN exists for, and Fly's UDP proxying is the least
battle-tested part of this whole setup.

When it fails, `fly logs --app fabtabletop-turn` distinguishes the causes:

| Log | Cause |
| --- | --- |
| a wall of `401` | the two `TURN_SECRET` values differ |
| `allocation quota reached` | the relay port range is too small |
| `ALLOCATE processed, success` but still no `relay` row | the allocation worked and the relay address is unreachable — check Gate A's relay line, and check the DNS record is grey-clouded |
| nothing at all | the Allocate request never arrived: network path, not auth |

##### Gate C — a real game

Two players, ideally one of them on cellular. Open `chrome://webrtc-internals`,
find the nominated candidate pair, and confirm `relay` appears when you would
expect it. This is also how you measure what fraction of real games need the
relay at all — the number that tells you whether to widen the port range.

#### 3.6 TLS (`turns:` on 443) — optional

Skip this if you just want to get playing; plain TURN already covers the
cellular case. Add it when you want the corporate/guest-wifi case too.

Plain TURN on 3478 covers symmetric NAT. It does **not** cover corporate and
guest wifi, which routinely drop 3478 and 5349 and permit only 443 — and those
are exactly the networks where a relay is the only thing that works.

**coturn does not handle the certificate.** `infrastructure/coturn/fly.toml`
gives port 443 the Fly `tls` handler, so Fly's edge terminates TLS and forwards
the decrypted stream to the same plain TURN listener on 3478 that serves port
3478. Fly issues and **auto-renews** the cert, so there is no rotation to do.

The DNS record from 3.2 is the prerequisite — Fly validates the certificate
against it, and a proxied (orange-cloud) record fails validation because the
challenge resolves to Cloudflare rather than to Fly.

> **Why not a Cloudflare Origin CA certificate?** Because the `turn` record is
> grey-cloud, the browser connects straight to Fly and validates the certificate
> itself. Origin CA certs are signed by a root that exists only inside
> Cloudflare's proxy and is in no public trust store — Cloudflare's own docs warn
> that "site visitors may see untrusted certificate errors if you [...] disable
> proxying on subdomains that use Cloudflare origin CA certificates", which is
> exactly our configuration. Orange-clouding the record to fix that is not an
> option either: Cloudflare does not forward UDP, so it would take plain TURN
> down to buy TLS. Cloudflare's role here is DNS, not certificates.

```bash
# 1. Have Fly issue and manage the cert for the hostname from 3.2.
fly certs add turn.fabtabletop.net --app fabtabletop-turn
fly certs show turn.fabtabletop.net --app fabtabletop-turn   # wait for "Ready"

# 2. Set the realm to match the hostname.
fly secrets set TURN_REALM="turn.fabtabletop.net" --app fabtabletop-turn

# 3. Advertise both arms to clients. The turns: URL must use the hostname the
#    cert was issued for — an IP will fail certificate validation.
fly secrets set \
  TURN_URLS="turn:turn.fabtabletop.net:3478,turns:turn.fabtabletop.net:443?transport=tcp" \
  --app fabtabletop
```

**Expect step 1 to need a DNS-01 challenge.** Fly validates with TLS-ALPN-01 or
DNS-01, and TLS-ALPN-01 wants an ordinary HTTPS-ish service to answer on 443 —
this app publishes no port 80 and its 443 is a raw TCP service forwarding to a
TURN listener. If `fly certs show` sits at *Awaiting configuration* rather than
moving to *Ready*, it is printing a validation target; add it at Cloudflare:

| Field | Value |
| --- | --- |
| Type | `CNAME` |
| Name | `_acme-challenge.turn` |
| Target | the `flydns.net` hostname from `fly certs show` |
| Proxy status | DNS only (Cloudflare forces this on underscore records) |

This is the one place Cloudflare genuinely helps: it hosts the challenge record,
Let's Encrypt reads it, and Fly renews against the same record automatically
from then on. Nothing to redo in 90 days.

Until a cert is issued, coturn boots without a TLS listener of its own and logs
an INFO line; plain TURN still works and only the strict-firewall case is lost.

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
certbot certonly --manual --preferred-challenges dns -d turn.fabtabletop.net
fly secrets set \
  TURN_TLS_CERT="$(base64 -w0 < /etc/letsencrypt/live/turn.fabtabletop.net/fullchain.pem)" \
  TURN_TLS_KEY="$(base64 -w0 < /etc/letsencrypt/live/turn.fabtabletop.net/privkey.pem)" \
  --app fabtabletop-turn
```

Both changes are needed together: with the secrets set but the fly.toml
untouched, coturn binds TLS on internal 443 while Fly is still forwarding
plaintext to 3478, so the listener you just configured is routed to by nothing.
The entrypoint prints a reminder when it takes this path.

`--manual` there means re-running it every 90 days. If you end up living on
this path, swap certbot for an ACME client driving the Cloudflare API instead —
`acme.sh --dns dns_cf`, `lego`, or `certbot-dns-cloudflare` with a scoped
**Zone:DNS:Edit** token — which renews unattended against the same DNS-01
challenge. The certificate is still Let's Encrypt; Cloudflare only answers the
challenge. You would still have to push the renewed PEM into `fly secrets` and
restart, which is the real reason to prefer the Fly-managed cert above. Only
take this path if the `tls` handler genuinely does not work.

#### Reference — what the entrypoint computes at boot

Three coturn arguments are derived rather than configured, and all three exist
because Fly's UDP path has constraints an ordinary host does not.

`INTERNAL_IP` — resolved from `fly-global-services`, overridable by setting the
env var (which is how the image is tested locally, outside Fly).

- **`--relay-ip=$INTERNAL_IP`.** Fly forwards UDP by rewriting only the
  destination IP — never the port — to whatever `fly-global-services` resolves
  to. Left to itself coturn picks relay addresses by enumerating interfaces and
  takes the IPv6 ones too, and Fly cannot route UDP over IPv6, so those
  allocations succeed and then carry no media. Pinning is what keeps every
  allocation on the one routable path.
- **`--external-ip=$EXTERNAL_IP/$INTERNAL_IP`.** The `public/private` mapping
  form, not a bare address: coturn sits behind Fly's NAT and has to know both
  the address it advertises and the local one behind it. The mapping form also
  whitelists the private address, which matters because `turnserver.conf` denies
  `172.16.0.0/12` as a peer range and `fly-global-services` lives inside it.
- **`listening-ip` is deliberately never set.** fly-proxy dials the TCP arm on a
  different interface than `fly-global-services`, so pinning the *listeners*
  there would take TURN-over-TCP — and with it the 443 TLS arm — dark. coturn
  binds each discovered address individually rather than wildcarding, so the UDP
  listener already replies from a correct source address without help. Only the
  relay side needs pinning.

The coturn image is pinned in `infrastructure/coturn/Dockerfile` (currently
`4.17.2-debian`). Pin it, don't track `latest`: coturn logs
`Bad configuration format` for an option name it does not recognise and then
boots anyway, so an image bump can disable a setting in `turnserver.conf`
without failing the deploy. Bump deliberately and re-read Gate A's log.

#### Reference — scaling out

TURN does **not** scale by adding machines to this app. An allocation lives on
one specific machine and the client must keep reaching that same machine for
the life of the call; several machines behind one Fly Anycast IP would spray a
client's packets across them and break allocations. `min_machines_running = 1`
with `auto_stop_machines = 'off'` is deliberate — scale this app *up*, never
*out*.

Nothing in `fly.toml` enforces that. Machine count is not a config field —
`min_machines_running` is the floor the autostop reaper will not go below, not a
ceiling, and there is no `max_machines_running` — so the count is only ever set
imperatively, by `fly deploy --ha=false` (3.4) and `fly scale count`. Which
means the one-machine invariant is a habit, not a guarantee: `fly status` is
what checks it, and Gate A is where to look.

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

Fly does not rewrite UDP ports, so for the relay range the external and internal
port numbers are necessarily the same; the `internal_port` on that service block
is a formality the schema requires. (TCP ports *are* rewritten, which is how the
443 service forwards to 3478.)

Budget one port per allocation: a relayed player costs one, and the
phone-as-camera flow is a second peer connection, so a fully-relayed game with
both players on phones costs 4. 100 ports is comfortable headroom for a beta.

#### Reference — testing the image without deploying

The whole container can be exercised locally, which is how the coturn version
above was validated. `INTERNAL_IP` stands in for `fly-global-services`:

```bash
docker build -f infrastructure/coturn/Dockerfile -t coturn-check .
docker run --rm -e TURN_SECRET=testsecret -e EXTERNAL_IP=203.0.113.9 \
  -e INTERNAL_IP=172.17.0.2 coturn-check
```

Read the boot log against Gate A's checklist. For an end-to-end credential test
— proving `Tabletop.Turn` and coturn agree on the HMAC — run coturn with the dev
config and allocate against it with coturn's own client:

```bash
docker compose up -d coturn
cd tabletop && mix run --no-start -e \
  'IO.inspect(Tabletop.Turn.ice_servers("relaytest"))'   # copy username + credential

docker run --rm --network host --entrypoint turnutils_uclient \
  coturn/coturn:4.17.2-debian -u '<username>' -w '<credential>' \
  -p 3478 -n 2 -m 1 -e 127.0.0.1 127.0.0.1
```

`ALLOCATE processed, success` in the coturn log means the credential scheme
works end to end. A `401` means the dev secret in `config/dev.exs` and
`infrastructure/coturn/coturn.dev.conf` have drifted apart.

Both commands rely on `network_mode: host`, which on macOS is off unless Docker
Desktop has host networking enabled — see the note in `docker-compose.yml`. To
sidestep that entirely, put the server and the client on a user-defined bridge
network instead and address the server by container name.

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
fly deploy --config infrastructure/fly/postgres.toml --ha=false

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
fly deploy --config infrastructure/fly/fly.toml --no-cache --ha=false
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
- **TURN_URLS**: Comma-separated `turn:`/`turns:` URLs on the web app (e.g. `turn:turn.fabtabletop.net:3478,turns:turn.fabtabletop.net:443?transport=tcp`). Unset ⇒ STUN-only.
- **EXTERNAL_IP** (`fabtabletop-turn`): **Required.** The dedicated IPv4 coturn advertises as the relay address. Not auto-detectable on Fly; the entrypoint exits if it's missing.
- **TURN_REALM** (`fabtabletop-turn`): Optional; defaults to `fabtabletop.fly.dev`. Set it to the TLS hostname once you have one.
- **INTERNAL_IP** (`fabtabletop-turn`): Optional override for the address coturn relays from. Resolved from `fly-global-services` at boot; set it only when running the image outside Fly, where that name does not resolve and the entrypoint otherwise exits.
- **TURN_TLS_CERT** / **TURN_TLS_KEY** (`fabtabletop-turn`): Optional base64 PEM pair, for the fallback where coturn terminates TLS itself instead of Fly. Absent is the normal case (§ 3.6); it is not an error.
- **MAILERSEND_API_KEY** / **MAILER_FROM_EMAIL**: Required for registration-confirmation emails — the app raises on boot if `MAILER_FROM_EMAIL` is unset.
- **METRICS_PORT**: Optional, defaults to `9091` — must match `[metrics]` in fly.toml
