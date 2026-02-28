defmodule TabletopWeb.GameLive.Show do
  use TabletopWeb, :live_view

  alias Tabletop.Games
  alias Tabletop.Fab.GameState

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Games.get_game!(socket.assigns.current_scope, id)
    user_id = socket.assigns.current_scope.user.id

    if connected?(socket) do
      Games.subscribe_games(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(Tabletop.PubSub, "game_session:#{game.id}")
    end

    if Games.user_part_of_game?(socket.assigns.current_scope, game) do
      user_token = Phoenix.Token.sign(socket, "user socket", user_id)

      {:ok,
       socket
       |> assign(:page_title, game.title)
       |> assign(:game, game)
       |> assign(:user_token, user_token)
       |> assign(:user_id, user_id)
       |> assign(:peer_connected, false)
       |> assign(:game_state, GameState.new())}
    else
      {:ok,
       socket
       |> put_flash(:error, "You are not a participant in this game.")
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- User events ---

  @impl true
  def handle_event("peer_connected", _params, socket) do
    {:noreply, assign(socket, :peer_connected, true)}
  end

  def handle_event("peer_disconnected", _params, socket) do
    {:noreply, assign(socket, :peer_connected, false)}
  end

  def handle_event("toggle_damage", %{"type" => type}, socket) do
    apply_my_action(
      socket,
      GameState.toggle_damage(socket.assigns.game_state, validate_damage_type(type))
    )
  end

  def handle_event("change_damage", %{"type" => type, "delta" => delta}, socket) do
    apply_my_action(
      socket,
      GameState.change_damage(
        socket.assigns.game_state,
        validate_damage_type(type),
        String.to_integer(delta)
      )
    )
  end

  def handle_event("toggle_goagain", _params, socket) do
    apply_my_action(socket, GameState.toggle_goagain(socket.assigns.game_state))
  end

  def handle_event("toggle_effect", %{"type" => type}, socket) do
    apply_my_action(socket, GameState.toggle_effect(socket.assigns.game_state, type))
  end

  def handle_event("change_life", %{"delta" => delta}, socket) do
    apply_my_action(
      socket,
      GameState.change_life(socket.assigns.game_state, String.to_integer(delta))
    )
  end

  def handle_event("reset_chain", _params, socket) do
    apply_my_action(socket, GameState.reset_chain(socket.assigns.game_state))
  end

  # --- PubSub messages ---

  @impl true
  def handle_info(
        {:game_update, _broadcast_msg, sender_id},
        %{assigns: %{user_id: sender_id}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_info({:game_update, broadcast_msg, _sender_id}, socket) do
    new_state = GameState.apply_opponent_update(socket.assigns.game_state, broadcast_msg)
    {:noreply, assign(socket, :game_state, new_state)}
  end

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
     |> push_navigate(to: ~p"/")}
  end

  def handle_info({type, %Tabletop.Games.Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end

  defp apply_my_action(socket, {:ok, new_state, broadcast_msg}) do
    broadcast_game_update(socket, broadcast_msg, socket.assigns.user_id)
    {:noreply, assign(socket, :game_state, new_state)}
  end

  defp apply_my_action(socket, {:error, reason}) do
    IO.inspect(reason, label: "Action error")
    {:noreply, socket}
  end

  defp validate_damage_type("physical"), do: :physical
  defp validate_damage_type("arcane"), do: :arcane

  defp broadcast_game_update(socket, broadcast_msg, user_id) do
    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{socket.assigns.game.id}",
      {:game_update, broadcast_msg, user_id}
    )
  end
end
