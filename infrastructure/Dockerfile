# Build stage
ARG ELIXIR_VERSION=1.19
ARG OTP_VERSION=28
ARG BUILDER_IMAGE="elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}"
ARG RUNNER_IMAGE="debian:trixie-slim"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

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
COPY tabletop/lib lib
COPY tabletop/assets assets
COPY tabletop/rel rel

# Copy runtime config and compile (must happen before assets.deploy
# so Phoenix generates colocated JS into _build/prod/phoenix-colocated/)
COPY tabletop/config/runtime.exs config/
RUN mix compile

# Compile assets (needs colocated JS from mix compile)
RUN mix assets.deploy

# Build the release
RUN mix release

# Runner stage
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates imagemagick \
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

CMD ["bin/tabletop", "start"]
