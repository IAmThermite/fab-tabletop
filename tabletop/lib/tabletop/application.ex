defmodule Tabletop.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TabletopWeb.Telemetry,
      Tabletop.Repo,
      {DNSCluster, query: Application.get_env(:tabletop, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tabletop.PubSub},
      %{id: :game_channels_pg, start: {:pg, :start_link, [:game_channels]}},
      # Start a worker by calling: Tabletop.Worker.start_link(arg)
      # {Tabletop.Worker, arg},
      # Start to serve requests, typically the last entry
      TabletopWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tabletop.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TabletopWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
