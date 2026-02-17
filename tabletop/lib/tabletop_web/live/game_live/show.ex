defmodule TabletopWeb.GameLive.Show do
  use TabletopWeb, :live_view

  alias Tabletop.Games
  alias Tabletop.Games.Game

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.game flash={@flash} current_scope={@current_scope}>
      <.header>
        Game {@game.id}
        <:subtitle>This is a game record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/games"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/games/#{@game}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit game
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Title">{@game.title}</:item>
        <:item title="Format">{Game.format_name(@game)}</:item>
        <:item title="Player 1">{@game.user.email}</:item>
        <:item :if={@game.user2} title="Player 2">{@game.user2.email}</:item>
      </.list>
    </Layouts.game>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Games.subscribe_games(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Show Game")
     |> assign(:game, Games.get_game!(socket.assigns.current_scope, id))}
  end

  @impl true
  def handle_info(
        {:updated, %Tabletop.Games.Game{id: id} = game},
        %{assigns: %{game: %{id: id}}} = socket
      ) do
    {:noreply, assign(socket, :game, game)}
  end

  def handle_info(
        {:deleted, %Tabletop.Games.Game{id: id}},
        %{assigns: %{game: %{id: id}}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "The current game was deleted.")
     |> push_navigate(to: ~p"/games")}
  end

  def handle_info({type, %Tabletop.Games.Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end
end
