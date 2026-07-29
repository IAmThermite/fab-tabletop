#!/bin/sh
# coturn entrypoint for Fly.io.
#
# Injects the auth secret, the relay's public IPv4 and (optionally) the TLS
# cert at container start, so none of them are baked into the image and none
# show up as command-line args in the fly.toml `cmd`.
set -eu

if [ -z "${TURN_SECRET:-}" ]; then
  echo "FATAL: TURN_SECRET is not set" >&2
  exit 1
fi

# A TURN server hands its own public address out as the relay address, so it
# MUST know it. On Fly the dedicated IPv4 lives on the edge proxy and never
# appears on a container interface, so there is nothing to auto-detect —
# EXTERNAL_IP has to be set explicitly to the address from
# `fly ips list --app fabtabletop-turn`.
#
# We deliberately do NOT fall back to FLY_PUBLIC_IP: that variable is the
# machine's *IPv6*, and advertising a v6 relay address for a v4 listener makes
# every allocation fail silently — far worse than refusing to boot.
if [ -z "${EXTERNAL_IP:-}" ]; then
  echo "FATAL: EXTERNAL_IP is not set." >&2
  echo "       Set it to the app's dedicated IPv4:" >&2
  echo "         fly ips list --app fabtabletop-turn" >&2
  echo "         fly secrets set EXTERNAL_IP=<ipv4> --app fabtabletop-turn" >&2
  exit 1
fi

set -- \
  -c /etc/coturn/turnserver.conf \
  --static-auth-secret="$TURN_SECRET" \
  --external-ip="$EXTERNAL_IP" \
  --realm="${TURN_REALM:-fabtabletop.fly.dev}"

# TLS (turns:) on 443. This is the arm that reaches players behind restrictive
# corporate/guest firewalls, which routinely drop 3478 but allow 443/TCP.
#
# Fly certs only cover the HTTP edge, so the cert has to be supplied to this
# app directly. Both secrets are base64-encoded PEM, which keeps the newlines
# intact through `fly secrets set`:
#
#   fly secrets set \
#     TURN_TLS_CERT="$(base64 -w0 < fullchain.pem)" \
#     TURN_TLS_KEY="$(base64 -w0 < privkey.pem)" \
#     --app fabtabletop-turn
#
# With no cert configured we pass --no-tls/--no-dtls rather than leaving a
# half-configured TLS listener that fails to bind and buries the reason in the
# logs. Plain TURN on 3478 (TCP + UDP) still works; only the strict-firewall
# case is lost.
if [ -n "${TURN_TLS_CERT:-}" ] && [ -n "${TURN_TLS_KEY:-}" ]; then
  mkdir -p /etc/coturn/tls
  printf '%s' "$TURN_TLS_CERT" | base64 -d > /etc/coturn/tls/cert.pem
  printf '%s' "$TURN_TLS_KEY" | base64 -d > /etc/coturn/tls/key.pem
  chmod 600 /etc/coturn/tls/key.pem

  set -- "$@" \
    --tls-listening-port=443 \
    --cert=/etc/coturn/tls/cert.pem \
    --pkey=/etc/coturn/tls/key.pem
else
  echo "WARN: TURN_TLS_CERT/TURN_TLS_KEY unset — turns: (TLS) disabled." >&2
  echo "      Players behind firewalls that only permit 443 will not connect." >&2
  set -- "$@" --no-tls --no-dtls
fi

exec turnserver "$@"
