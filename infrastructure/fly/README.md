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

# Deploy
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

Migrations run automatically if configured in the Phoenix release. To run manually:

```bash
fly ssh console -c infrastructure/fly/fly.toml -C "/app/bin/tabletop eval 'Tabletop.Release.migrate()'"
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

## Cost

Both apps run on the free VM allowance:
- Web app: shared-cpu-1x, 256MB (scales to zero when idle)
- Postgres: shared-cpu-1x, 256MB, 1GB volume (always on)
- Automatic TLS certificates included
