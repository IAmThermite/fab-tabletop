defmodule TabletopWeb.GameLive.Index do
  use TabletopWeb, :live_view

  alias Tabletop.Games
  alias Tabletop.Games.Game

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} max_width="max-w-7xl">
      <.header>
        Listing Games
        <:actions>
          <.button variant="primary" navigate={~p"/games/new"}>
            <.icon name="hero-plus" /> New Game
          </.button>
        </:actions>
      </.header>

      <div id="game-content" class="grid grid-cols-3 gap-4">
        <div>
          <.table
            id="games"
            rows={@streams.games}
            row_click={fn {_id, game} -> JS.navigate(~p"/games/#{game}") end}
          >
            <:col :let={{_id, game}} label="Game Title">{game.title}</:col>
            <:col :let={{_id, game}} label="Format">{Game.format_name(game)}</:col>
            <:action :let={{_id, game}}>
              <div class="sr-only">
                <.link navigate={~p"/games/#{game}"}>Show</.link>
              </div>
              <.link navigate={~p"/games/#{game}/edit"}>Edit</.link>
            </:action>
            <:action :let={{id, game}}>
              <.link
                phx-click={JS.push("delete", value: %{id: game.id}) |> hide("##{id}")}
                data-confirm="Are you sure?"
              >
                Delete
              </.link>
            </:action>
          </.table>
        </div>
        <div>
          <p>test</p>
        </div>
        <div>
          <p>test</p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Games.subscribe_games(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Games")
     |> stream(:games, list_games(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    game = Games.get_game!(socket.assigns.current_scope, id)
    {:ok, _} = Games.delete_game(socket.assigns.current_scope, game)

    {:noreply, stream_delete(socket, :games, game)}
  end

  @impl true
  def handle_info({type, %Tabletop.Games.Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, stream(socket, :games, list_games(socket.assigns.current_scope), reset: true)}
  end

  defp list_games(current_scope) do
    Games.list_games(current_scope)
  end
end
