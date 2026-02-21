defmodule TabletopWeb.GameChannel do
  use Phoenix.Channel

  alias Tabletop.Repo
  alias Tabletop.Games.Game

  @impl true
  def join("game:" <> game_id, _payload, socket) do
    user_id = socket.assigns.user_id

    case Repo.get(Game, game_id) do
      %Game{user_id: ^user_id} ->
        send(self(), :after_join)
        {:ok, assign(socket, :game_id, game_id)}

      %Game{user2_id: ^user_id} ->
        send(self(), :after_join)
        {:ok, assign(socket, :game_id, game_id)}

      _other ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    broadcast_from!(socket, "peer_joined", %{user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, socket) do
    broadcast_from!(socket, "offer", %{sdp: sdp})
    {:noreply, socket}
  end

  def handle_in("answer", %{"sdp" => sdp}, socket) do
    broadcast_from!(socket, "answer", %{sdp: sdp})
    {:noreply, socket}
  end

  def handle_in("ice_candidate", %{"candidate" => candidate}, socket) do
    broadcast_from!(socket, "ice_candidate", %{candidate: candidate})
    {:noreply, socket}
  end

  def handle_in("media_status", %{"camera" => camera, "mic" => mic}, socket) do
    broadcast_from!(socket, "media_status", %{camera: camera, mic: mic})
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    broadcast_from!(socket, "peer_left", %{user_id: socket.assigns.user_id})
    :ok
  end
end
