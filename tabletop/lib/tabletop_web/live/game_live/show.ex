defmodule TabletopWeb.GameLive.Show do
  use TabletopWeb, :live_view

  alias Tabletop.Games

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    game = Games.get_game!(socket.assigns.current_scope, id)

    if connected?(socket) do
      Games.subscribe_games(socket.assigns.current_scope)
      Phoenix.PubSub.subscribe(Tabletop.PubSub, "game_session:#{game.id}")
    end

    user_token = Phoenix.Token.sign(socket, "user socket", socket.assigns.current_scope.user.id)

    {:ok,
      socket
      |> assign(:page_title, game.title)
      |> assign(:game, game)
      |> assign(:user_token, user_token)
      |> assign(:my_life, 40)
      |> assign(:opponent_life, 40)
      |> assign(:peer_connected, false)
      |> assign(:my_physical_damage, 0)
      |> assign(:my_arcane_damage, 0)
      |> assign(:my_goagain_active, false)
      |> assign(:my_physical_active, false)
      |> assign(:my_arcane_active, false)
      |> assign(:my_effects_active, %{}) # a map of effect name to boolean
      |> assign(:opponent_physical_damage, 0)
      |> assign(:opponent_arcane_damage, 0)
      |> assign(:opponent_goagain_active, false)
      |> assign(:opponent_physical_active, false)
      |> assign(:opponent_arcane_active, false)
      |> assign(:opponent_effects_active, %{}) # a map of effect name to boolean
    }
  end

  @impl true
  def handle_event("peer_connected", _params, socket) do
    {:noreply, assign(socket, :peer_connected, true)}
  end

  def handle_event("peer_disconnected", _params, socket) do
    {:noreply, assign(socket, :peer_connected, false)}
  end

  def handle_event("toggle_damage", %{"type" => type}, socket) do
    key = String.to_atom("#{type}_toggled")
    broadcast_game_update(socket, key, !Map.get(socket.assigns, :opponent_damage_active), socket.assigns.current_scope.user.id)
    {:noreply, assign(socket, :my_damage_active, !Map.get(socket.assigns, :my_damage_active))}
  end

  def handle_event("change_damage", %{"type" => type, "delta" => delta}, socket) do
    key = String.to_existing_atom("#{type}_damage")
    new_value = Map.get(socket.assigns, key) + String.to_integer(delta)
    {:noreply, assign(socket, key, new_value)}
  end

  def handle_event("toggle_goagain", _params, socket) do
    broadcast_game_update(socket, :goagain_toggled, !socket.assigns.my_goagain_active, socket.assigns.current_scope.user.id)
    {:noreply, assign(socket, :my_goagain_active, !socket.assigns.my_goagain_active)}
  end

  def handle_event("toggle_effect", %{"type" => type}, socket) do
    my_key = String.to_atom("my_#{type}_active")
    opponent_key = String.to_atom("opponent_#{type}_active")
    {:noreply, assign(socket, opponent_key, !Map.get(socket.assigns, my_key))}
  end

  def handle_event("change_life", %{"delta" => delta}, socket) do
    new_life = socket.assigns.my_life + String.to_integer(delta)

    broadcast_game_update(socket, :life_changed, new_life, socket.assigns.current_scope.user.id)

    {:noreply, assign(socket, :my_life, new_life)}
  end

  @impl true
  def handle_info({:life_changed, life, user_id}, socket) do
    if user_id != socket.assigns.current_scope.user.id do
      {:noreply, assign(socket, :opponent_life, life)}
    else
      # we don't subscribe to our own life changes, ignore them
      {:noreply, socket}
    end
  end

  def handle_info({:goagain_toggled, active, user_id}, socket) do
    if user_id != socket.assigns.current_scope.user.id do
      {:noreply, assign(socket, :opponent_goagain_active, active)}
    else
      # we don't subscribe to our own go again toggles, ignore them
      {:noreply, socket}
    end
  end

  def handle_info({:physical_toggled, active, user_id}, socket) do
    if user_id != socket.assigns.current_scope.user.id do
      key = String.to_atom("opponent_physical_active")
      {:noreply, assign(socket, key, active)}
    else
      # we don't subscribe to our own physical damage toggles, ignore them
      {:noreply, socket}
    end
  end

  def handle_info({:arcane_toggled, active, user_id}, socket) do
    if user_id != socket.assigns.current_scope.user.id do
      key = String.to_atom("opponent_arcane_active")
      {:noreply, assign(socket, key, active)}
    else
      # we don't subscribe to our own arcane damage toggles, ignore them
      {:noreply, socket}
    end
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
     |> push_navigate(to: ~p"/games")}
  end

  def handle_info({type, %Tabletop.Games.Game{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, socket}
  end

  defp broadcast_game_update(socket, event, payload, user_id) do
    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{socket.assigns.game.id}",
      {event, payload, user_id}
    )
  end
end
