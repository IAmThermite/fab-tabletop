#!/bin/sh
# coturn entrypoint for Fly.io.
#
# Injects the auth secret, the relay addresses and (optionally) the TLS cert at
# container start, so none of them are baked into the image and none show up as
# command-line args in the fly.toml `cmd`.
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

# --- Where the relay sockets live ---
#
# Fly forwards UDP by rewriting only the destination IP — never the port — and
# it forwards to whatever `fly-global-services` resolves to. coturn's relay
# sockets have to sit on that exact address.
#
# Left to itself coturn picks relay addresses by enumerating interfaces, and it
# takes the IPv6 ones too (locally it selects `::1`; on Fly it would take the
# 6PN `fdaa::` address). Fly cannot route UDP over IPv6 at all, so allocations
# handed out on those addresses succeed and then silently carry no media.
# Naming the address explicitly keeps every allocation on the one routable path.
#
# `listening-ip` is deliberately NOT set. fly-proxy dials the TCP arm on a
# different interface than fly-global-services, so pinning the listeners here
# would take TURN-over-TCP — and with it the 443 TLS arm — dark. coturn binds
# each discovered address individually rather than wildcarding, so the UDP
# listener already replies from a correct source address without help; only the
# relay side needs pinning.
INTERNAL_IP="${INTERNAL_IP:-$(getent ahostsv4 fly-global-services 2>/dev/null | awk 'NR==1 {print $1}')}"

if [ -z "$INTERNAL_IP" ]; then
  echo "FATAL: could not resolve 'fly-global-services' to an IPv4 address." >&2
  echo "       Without it coturn picks its own relay addresses and hands out" >&2
  echo "       ones Fly cannot route — allocations succeed and carry no media," >&2
  echo "       so this is a hard failure rather than a fallback." >&2
  echo "       Outside Fly (local docker), set INTERNAL_IP explicitly." >&2
  exit 1
fi

# --external-ip takes a `public/private` mapping rather than a bare address:
# coturn is behind Fly's NAT, so it must know both the address it advertises
# and the local one that corresponds to it. The mapping form also whitelists
# the private address, which matters because turnserver.conf denies
# 172.16.0.0/12 as a peer range and fly-global-services lives inside it.
set -- \
  -c /etc/coturn/turnserver.conf \
  --static-auth-secret="$TURN_SECRET" \
  --relay-ip="$INTERNAL_IP" \
  --external-ip="$EXTERNAL_IP/$INTERNAL_IP" \
  --realm="${TURN_REALM:-fabtabletop.fly.dev}"

echo "coturn: relaying on $INTERNAL_IP, advertised as $EXTERNAL_IP" >&2

# TLS (turns:) on 443. This is the arm that reaches players behind restrictive
# corporate/guest firewalls, which routinely drop 3478 but allow 443/TCP.
#
# The default deployment does NOT use this path — fly.toml gives port 443 the
# Fly `tls` handler, so Fly's edge terminates TLS and forwards plaintext to the
# ordinary 3478 listener, and coturn never sees a certificate. These secrets
# are the fallback for when that handler doesn't work; taking it also means
# repointing the 443 service to internal_port 443 in fly.toml, or the listener
# below binds a port nothing routes to. See ../fly/README.md § 3.6.
#
# Both secrets are base64-encoded PEM, which keeps the newlines intact through
# `fly secrets set`:
#
#   fly secrets set \
#     TURN_TLS_CERT="$(base64 -w0 < fullchain.pem)" \
#     TURN_TLS_KEY="$(base64 -w0 < privkey.pem)" \
#     --app fabtabletop-turn
#
# With no cert configured we pass --no-tls rather than leaving a
# half-configured TLS listener that fails to bind and buries the reason in the
# logs. Plain TURN on 3478 (TCP + UDP) still works, and the Fly-terminated 443
# arm is unaffected either way.
if [ -n "${TURN_TLS_CERT:-}" ] && [ -n "${TURN_TLS_KEY:-}" ]; then
  mkdir -p /etc/coturn/tls
  printf '%s' "$TURN_TLS_CERT" | base64 -d > /etc/coturn/tls/cert.pem
  printf '%s' "$TURN_TLS_KEY" | base64 -d > /etc/coturn/tls/key.pem
  chmod 600 /etc/coturn/tls/key.pem

  set -- "$@" \
    --tls-listening-port=443 \
    --cert=/etc/coturn/tls/cert.pem \
    --pkey=/etc/coturn/tls/key.pem

  echo "coturn: terminating TLS itself on 443 — fly.toml's 443 service must" >&2
  echo "        point at internal_port 443 with no 'tls' handler for this to" >&2
  echo "        be reachable." >&2
else
  echo "INFO: TURN_TLS_CERT/TURN_TLS_KEY unset — coturn is not terminating TLS." >&2
  echo "      This is expected: with the Fly 'tls' handler on port 443, Fly" >&2
  echo "      terminates and forwards to 3478. turns: works once a cert is" >&2
  echo "      issued with 'fly certs add' (see ../fly/README.md § 3.6)." >&2
  # Only --no-tls: on coturn 4.17 --no-dtls is deprecated and redundant
  # ("DTLS listeners are not started unless --dtls is given").
  set -- "$@" --no-tls
fi

exec turnserver "$@"
