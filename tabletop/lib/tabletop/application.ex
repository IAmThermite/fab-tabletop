defmodule Tabletop.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attaches the span handlers before the endpoint accepts a connection, so no
    # request is served untraced. Building spans is cheap and the exporter is a
    # no-op unless configured, so this runs in every environment.
    Tabletop.Tracing.setup()

    children =
      [
        TabletopWeb.Telemetry,
        # Starts before the Repo and Endpoint so the metric handlers are attached
        # before anything they measure can emit.
        Tabletop.PromEx,
        Tabletop.Repo,
        {DNSCluster, query: Application.get_env(:tabletop, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Tabletop.PubSub},
        %{id: :game_channels_pg, start: {:pg, :start_link, [:game_channels]}},
        {Registry, keys: :unique, name: Tabletop.Games.LeaveTimerRegistry},
        {Registry, keys: :duplicate, name: Tabletop.Games.GameConnectionRegistry},
        {DynamicSupervisor,
         name: Tabletop.Games.LeaveTimerSupervisor, strategy: :one_for_one, max_children: 1_000},
        {Registry, keys: :unique, name: Tabletop.Games.GameSessionRegistry},
        {DynamicSupervisor,
         name: Tabletop.Games.GameSessionSupervisor, strategy: :one_for_one, max_children: 1_000},
        # Start to serve requests, typically the last entry
        TabletopWeb.Endpoint
      ] ++ metrics_server()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tabletop.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The Prometheus scrape listener, on its own port so it is never reachable
  # through the public endpoint. Disabled by setting the port to `nil` — the
  # test env does this, since a fixed port would collide across concurrent runs.
  defp metrics_server do
    case Application.get_env(:tabletop, :metrics_port) do
      nil -> []
      port -> [{Tabletop.PromEx.MetricsServer, port: port}]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TabletopWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
