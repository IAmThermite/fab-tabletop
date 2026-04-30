defmodule TabletopWeb.TournamentLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Tournaments
  alias Tabletop.Tournaments.Tournament
  alias Tabletop.Accounts.Scope

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tournaments.subscribe_tournaments()

    {:ok,
     socket
     |> assign(:page_title, "Tournaments")
     |> assign(:tournaments, Tournaments.list_tournaments())}
  end

  @impl true
  def handle_info({:tournaments_updated}, socket) do
    {:noreply, assign(socket, :tournaments, Tournaments.list_tournaments())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Tournaments
        <:subtitle>Browse and join Flesh and Blood tournaments.</:subtitle>
        <:actions :if={Scope.admin?(@current_scope)}>
          <.button navigate={~p"/tournaments/new"} variant="primary">New Tournament</.button>
        </:actions>
      </.header>

      <div :if={@tournaments == []} class="text-center py-12 opacity-60">
        No tournaments yet.
      </div>

      <ul class="divide-y divide-base-300">
        <li :for={t <- @tournaments} class="py-4">
          <.link navigate={~p"/tournaments/#{t}"} class="block hover:bg-base-200 rounded p-2">
            <div class="flex items-center justify-between gap-4">
              <div>
                <div class="font-semibold text-lg">{t.name}</div>
                <div class="text-sm opacity-70">
                  {Tournament.format_name(t)} · {t.active_player_count}/{t.max_players} players
                </div>
              </div>
              <span class={"badge #{status_class(t.status)}"}>{status_label(t.status)}</span>
            </div>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp status_class(:draft), do: "badge-ghost"
  defp status_class(:registration), do: "badge-primary"
  defp status_class(:swiss), do: "badge-info"
  defp status_class(:cut), do: "badge-warning"
  defp status_class(:finished), do: "badge-success"
  defp status_class(:cancelled), do: "badge-error"

  defp status_label(:draft), do: "Draft"
  defp status_label(:registration), do: "Registration open"
  defp status_label(:swiss), do: "Swiss"
  defp status_label(:cut), do: "Top cut"
  defp status_label(:finished), do: "Finished"
  defp status_label(:cancelled), do: "Cancelled"
end
