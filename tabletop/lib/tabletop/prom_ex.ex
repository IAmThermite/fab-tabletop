defmodule Tabletop.PromEx do
  @moduledoc """
  Prometheus metric collection and exposition.

  Metrics are served by `Tabletop.PromEx.MetricsServer` on its own port,
  deliberately separate from `TabletopWeb.Endpoint`, so `/metrics` is never
  routable from the public HTTP service. Fly.io scrapes that port over the
  private 6PN network every 15s — see the `[metrics]` block in
  `infrastructure/fly/fly.toml`.

  `Tabletop.PromEx.GamePlugin` carries the app-specific signals (card scanner
  hit rate, game sessions, leave timers, camera relay, Swiss pairing); the rest
  are PromEx's stock plugins, each with a matching pre-built Grafana dashboard
  listed in `dashboards/0`.

  Note that metrics live in the machine's memory. With `auto_stop_machines`
  enabled the counters reset on every cold start — `rate()` handles that, but
  gauges will show gaps while the machine is stopped.
  """

  use PromEx, otp_app: :tabletop

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      {Plugins.Application, otp_app: :tabletop},
      Plugins.Beam,
      {Plugins.Phoenix, router: TabletopWeb.Router, endpoint: TabletopWeb.Endpoint},
      {Plugins.Ecto, otp_app: :tabletop, repos: [Tabletop.Repo]},
      Plugins.PhoenixLiveView,
      Tabletop.PromEx.GamePlugin
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "prometheus",
      default_selected_interval: "30s"
    ]
  end

  @impl true
  def dashboards do
    [
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"},
      {:prom_ex, "ecto.json"},
      {:prom_ex, "phoenix_live_view.json"}
    ]
  end
end
