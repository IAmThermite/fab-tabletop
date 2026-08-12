defmodule TabletopWeb.GameChannel do
  use Phoenix.Channel

  require Logger

  alias Tabletop.Repo
  alias Tabletop.Games.Game
  alias TabletopWeb.ChannelSeat

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
    %{game_id: game_id, user_id: user_id} = socket.assigns

    # Take this player's seat before announcing ourselves, so the topic holds at
    # most one socket per player and the exchange below stays the two-party
    # conversation it is written as. A second tab would otherwise put three
    # sockets on a topic whose every signalling message is an unaddressed
    # fan-out — see TabletopWeb.ChannelSeat.
    ChannelSeat.claim(seat(game_id, user_id))

    group = game_group(game_id)

    # Check for existing peers before registering ourselves
    has_peer = :pg.get_members(:game_channels, group) != []

    # Register ourselves in the process group
    :pg.join(:game_channels, group, self())

    # Notify existing peers that we joined.
    # The recipient of this broadcast will create the WebRTC offer.
    broadcast_from!(socket, "peer_joined", %{user_id: user_id})

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

  def handle_info(:superseded, socket) do
    # A newer connection for this player has taken the seat — another tab, or a
    # reconnect that raced its predecessor's shutdown. Tell the client so it can
    # say as much instead of appearing to lose its video for no reason, then
    # stand down.
    push(socket, "superseded", %{})
    {:stop, :normal, assign(socket, :superseded, true)}
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

  def handle_in(event, _payload, socket) do
    Logger.warning("GameChannel: ignoring unexpected event #{inspect(event)} on #{socket.topic}")
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, %{assigns: %{game_id: game_id, user_id: user_id}} = socket) do
    ChannelSeat.release(seat(game_id, user_id))
    :pg.leave(:game_channels, game_group(game_id), self())

    # A superseded socket's replacement is already on the topic and about to
    # renegotiate; from the opponent's side this player never left. Announcing
    # `peer_left` here would tear down the connection the replacement is in the
    # middle of building, and nothing would offer again.
    if !socket.assigns[:superseded] do
      broadcast_from!(socket, "peer_left", %{user_id: user_id})
    end

    :ok
  end

  def terminate(_, _), do: :ok

  defp game_group(game_id), do: {:game_channel, game_id}

  # One socket per player per game. Not keyed by socket kind: the topic must
  # hold two sockets in total, whatever token each authenticated with.
  defp seat(game_id, user_id), do: {:game_seat, game_id, user_id}
end
