#!/bin/sh
# coturn entrypoint for Fly.io.
#
# Injects the shared auth secret and the machine's public IPv4 at runtime so
# the secret is never baked into the image (and isn't visible in `fly` process
# listings the way a command-line arg on the fly.toml `cmd` would be).
set -eu

if [ -z "${TURN_SECRET:-}" ]; then
  echo "FATAL: TURN_SECRET is not set" >&2
  exit 1
fi

# Fly exposes the machine's public IPv4 via the dedicated address we allocate.
# Prefer an explicitly provided EXTERNAL_IP; otherwise try Fly's metadata.
EXTERNAL_IP="${EXTERNAL_IP:-${FLY_PUBLIC_IP:-}}"

EXTERNAL_IP_ARG=""
if [ -n "$EXTERNAL_IP" ]; then
  EXTERNAL_IP_ARG="--external-ip=$EXTERNAL_IP"
fi

exec turnserver \
  -c /etc/coturn/turnserver.conf \
  --static-auth-secret="$TURN_SECRET" \
  $EXTERNAL_IP_ARG
