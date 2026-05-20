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

```bash
# Create the TURN app (config + Dockerfile live in infrastructure/coturn/).
# Run from the repo root — the Dockerfile COPYs paths relative to root.
fly launch --config infrastructure/coturn/fly.toml --no-deploy

# TURN must own a stable public IP and hand it out as the relay address,
# so allocate a DEDICATED IPv4 (shared Anycast v4 will not work). ~$2/mo.
fly ips allocate-v4 --app fabtabletop-turn

# Generate a shared secret and set it on the TURN app.
TURN_SECRET=$(openssl rand -hex 32)
fly secrets set TURN_SECRET="$TURN_SECRET" --app fabtabletop-turn

# Deploy coturn.
fly deploy --config infrastructure/coturn/fly.toml

# Find the dedicated IPv4 you allocated:
fly ips list --app fabtabletop-turn

# Point the web app at the TURN server with the SAME secret.
# TURN_URLS is comma-separated; use the dedicated IPv4 from above.
fly secrets set \
  TURN_SECRET="$TURN_SECRET" \
  TURN_URLS="turn:<turn-ipv4>:3478" \
  --app fabtabletop
```

The relay UDP port range (`49160-49169`) is declared in both
`infrastructure/coturn/turnserver.conf` (`min-port`/`max-port`) and
`infrastructure/coturn/fly.toml` (one `[[services]]` block per port). Keep them
in sync — Fly only routes ports it knows about. Widen both together if you need
more concurrent relayed calls.

**Verify TURN works** with the [Trickle ICE tester](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/):
enter `turn:<turn-ipv4>:3478` plus a username/credential pair (mint one in
`iex` via `Tabletop.Turn.ice_servers("test")`), and confirm a candidate of type
`relay` appears. If you only see `host`/`srflx`, TURN isn't reachable.

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

## Environment

- **PHX_HOST**: Set in fly.toml — update this after adding a custom domain
- **DATABASE_URL**: Set via `fly secrets set`, uses Fly private DNS (`.internal`, IPv6)
- **ECTO_IPV6**: Set in fly.toml — required because `.internal` DNS resolves to IPv6
- **SECRET_KEY_BASE**: Set via `fly secrets set`
- **TURN_SECRET**: Shared HMAC secret for TURN auth — must be identical on the web app and the `fabtabletop-turn` app. If unset, clients fall back to STUN-only.
- **TURN_URLS**: Comma-separated `turn:`/`turns:` URLs on the web app (e.g. `turn:<turn-ipv4>:3478`).
- **MAILERSEND_API_KEY** / **MAILER_FROM_EMAIL**: Required for registration-confirmation emails — the app raises on boot if `MAILER_FROM_EMAIL` is unset.
