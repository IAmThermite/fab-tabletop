defmodule Tabletop.PromEx.MetricsServer do
  @moduledoc """
  Standalone Prometheus exposition listener.

  Runs a Bandit listener on its own port so the scrape endpoint is not reachable
  through `TabletopWeb.Endpoint` — nothing on the public `http_service` routes to
  `/metrics`, and the port is never published in `fly.toml`'s `[http_service]`.

  PromEx ships its own metrics server, but it is built on `Plug.Cowboy`; the app
  already runs Bandit, so serving the plug ourselves avoids pulling a second web
  server into the release.

  Binds `{0, 0, 0, 0, 0, 0, 0, 0}` to match `TabletopWeb.Endpoint` in
  `runtime.exs`. Fly's private network is IPv6, and an IPv6 any-address socket
  also accepts IPv4-mapped connections, so this covers both the 6PN scrape and
  local `curl` during development.
  """

  use Plug.Router

  plug(:match)
  plug(PromEx.Plug, prom_ex_module: Tabletop.PromEx)
  plug(:dispatch)

  # PromEx.Plug halts on the metrics path; anything else falls through to here.
  match _ do
    send_resp(conn, 404, "not found")
  end

  def child_spec(opts) do
    bandit_opts = [
      plug: __MODULE__,
      scheme: :http,
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: Keyword.fetch!(opts, :port),
      # The scrape endpoint is internal; its startup banner would just be noise.
      startup_log: false
    ]

    Supervisor.child_spec({Bandit, bandit_opts}, id: __MODULE__)
  end
end
