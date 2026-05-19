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
    group = game_group(socket.assigns.game_id)

    # Check for existing peers before registering ourselves
    has_peer = :pg.get_members(:game_channels, group) != []

    # Register ourselves in the process group
    :pg.join(:game_channels, group, self())

    # Notify existing peers that we joined.
    # The recipient of this broadcast will create the WebRTC offer.
    broadcast_from!(socket, "peer_joined", %{user_id: socket.assigns.user_id})

    # If we're the second joiner, the first joiner's broadcast was lost
    # (we weren't listening yet). But the first joiner will receive our
    # broadcast_from! above and initiate signaling, so we don't need
    # to do anything — we'll receive their offer shortly.
    # We do need to know a peer exists for status display though.
    if has_peer do
      push(socket, "peer_exists", %{})
    end

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

  @impl true
  def terminate(_reason, socket) do
    :pg.leave(:game_channels, game_group(socket.assigns.game_id), self())
    broadcast_from!(socket, "peer_left", %{user_id: socket.assigns.user_id})
    :ok
  end

  defp game_group(game_id), do: {:game_channel, game_id}
end
