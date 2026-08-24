# Grafana Alloy with the database observability config baked in.
#
# Fly has no way to mount a plain config file into a machine, and the config
# holds no secrets (every value comes from the environment), so shipping it in
# the image is simpler than a volume — and it means `fly deploy` is the only
# step needed to roll out a config change.
FROM grafana/alloy:v1.18.1

# Repo-root-relative, because flyctl resolves `build.dockerfile` against the
# config file's directory but uses the *working directory* as the build context —
# and every `fly deploy` in this repo is run from the repo root (see
# infrastructure/fly/README.md). Build locally the same way, or the COPY misses:
#   docker build -f infrastructure/monitoring/alloy.Dockerfile .
COPY infrastructure/monitoring/config.alloy /etc/alloy/config.alloy

# The base image's CMD already runs `/etc/alloy/config.alloy`; it is repeated
# here so the storage path and listen address stay explicit and reviewable.
# The HTTP UI binds to the 6PN address only — the Fly app declares no services,
# so it is reachable over WireGuard (`fly proxy 12345 -a fabtabletop-alloy`)
# and from nowhere else.
CMD ["run", "--server.http.listen-addr=[::]:12345", "--storage.path=/var/lib/alloy/data", "/etc/alloy/config.alloy"]
