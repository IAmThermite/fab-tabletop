defmodule Tabletop.Tracing do
  @moduledoc """
  OpenTelemetry span instrumentation, exported over OTLP to Grafana Tempo.

  Spans are batched and **pushed** over OTLP, so nothing needs to reach into the
  machine to collect them.

  One consequence of batching to keep in mind: spans buffered when the VM stops
  are lost. The machine no longer auto-stops (`auto_stop_machines = 'off'`), so
  in practice that means a deploy. `OTEL_BSP_SCHEDULE_DELAY_MILLIS` in
  `fly.toml` sets how long that window is.

  ## What produces spans

  `setup/0` attaches handlers to telemetry events the libraries already emit;
  no application code changes are needed:

    * **Bandit** (`opentelemetry_bandit`) — the outermost HTTP server span,
      including requests that never reach a route.
    * **Phoenix** (`opentelemetry_phoenix`) — endpoint + router spans, and,
      because `liveview: true` is the default, `mount`/`handle_event`/
      `handle_params` spans. The latter is the interesting part here: most of
      this app's behaviour lives in LiveView callbacks rather than in
      controllers, so without it a trace would show a socket connect and
      nothing else.
    * **Ecto** (`opentelemetry_ecto`) — one span per query, nested under
      whichever callback issued it.

  Order matters: Bandit is set up first so its span is the parent of the Phoenix
  span rather than a sibling.

  ## Disabled unless configured

  The exporter's default target is `http://localhost:4318`. With nothing
  listening there, every batch fails and the failures are logged, so
  `config.exs` ships `traces_exporter: :none` and `runtime.exs` only switches it
  to `:otlp` when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Handlers are attached
  either way — spans are simply built and dropped — which keeps the
  instrumented path identical whether or not traces are being exported.
  """

  require Logger

  @doc """
  Attaches the telemetry handlers that turn library events into spans.

  Called from `Tabletop.Application.start/2` before the endpoint starts
  serving, so no request can be missed. Safe to call once per boot only —
  `:telemetry.attach/4` rejects duplicate handler ids, and the underlying
  setup functions raise on a second call.
  """
  def setup do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)

    # `db_statement: :enabled` records the SQL on each span. Ecto sends
    # parameterised queries — values travel separately as `$1`, `$2` — so the
    # recorded statement carries no user data. Without this the DB spans show
    # timing but not which query, which is most of why you'd open one.
    OpentelemetryEcto.setup([:tabletop, :repo], db_statement: :enabled)

    if exporting?() do
      Logger.info("OpenTelemetry: exporting traces via OTLP")
    end

    :ok
  end

  @doc """
  True when spans are actually being shipped rather than built and dropped.

  Useful in a release console to tell "tracing is off" apart from "tracing is on
  but Tempo is rejecting us".
  """
  def exporting? do
    Application.get_env(:opentelemetry, :traces_exporter) == :otlp
  end
end
