# Build stage
ARG ELIXIR_VERSION=1.19
ARG OTP_VERSION=28
ARG BUILDER_IMAGE="elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}"
ARG RUNNER_IMAGE="debian:trixie-slim"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Node exists solely to `npm ci` the JS runtime dependencies that esbuild then
# bundles (@sentry/browser). Everything else in the asset pipeline runs on the
# standalone esbuild/tailwind binaries and needs no Node at all.
#
# Copied from the official image rather than installed with apt, which ships a
# much older Node. The tag tracks the builder's own Debian release (trixie) so
# the glibc matches, and the major matches .tool-versions.
COPY --from=node:24-trixie-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:24-trixie-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm

WORKDIR /app

ENV MIX_ENV="prod"

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY tabletop/mix.exs tabletop/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config before compiling deps
COPY tabletop/config/config.exs tabletop/config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application code
COPY tabletop/priv priv
# Bundle the precomputed card data set (from the flesh-and-blood-cards submodule)
# into priv so `Tabletop.Release.import_cards` can seed the DB in prod. Requires
# the submodule to be checked out in the build context (git submodule update --init).
COPY vendor/flesh-and-blood-cards/json/english/card.json priv/cards/card.json
COPY tabletop/lib lib
COPY tabletop/assets assets
COPY tabletop/rel rel
RUN chmod +x rel/overlays/bin/migrate rel/overlays/bin/server

# Copy runtime config and compile (must happen before assets.deploy
# so Phoenix generates colocated JS into _build/prod/phoenix-colocated/)
COPY tabletop/config/runtime.exs config/
RUN mix compile

# JS runtime dependencies for the bundle. `npm ci` (not `install`) so the build
# is reproducible from package-lock.json and never silently resolves a new
# version. `--omit=dev` skips pngjs, which only the Node asset tests use.
RUN npm ci --prefix assets --omit=dev

# Compile assets (needs colocated JS from mix compile and node_modules above)
RUN mix assets.deploy

# Package source into priv/sentry.map so Sentry issues show surrounding source.
RUN mix sentry.package_source_code

# Build the release
RUN mix release

# Runner stage
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"
ENV PHX_SERVER="true"

# Only copy the release artifact from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/tabletop ./

USER nobody

EXPOSE 4000
# Prometheus scrape endpoint. Reachable only over Fly's private 6PN network —
# it is not part of [http_service] in fly.toml, so it is never public.
EXPOSE 9091

CMD ["bin/tabletop", "start"]
