defmodule TabletopWeb.CameraRelayChannel do
  use Phoenix.Channel

  require Logger

  alias TabletopWeb.ChannelSeat

  @impl true
  def join("camera_relay:" <> relay_user_id, _payload, socket) do
    # The relay topic is keyed by user_id, which is stable across page mounts.
    # (The signed token can't be the topic — it's regenerated on every mount,
    # so the phone and desktop would land in different topics.) The socket is
    # already authenticated in UserSocket; here we just confirm the joining
    # socket belongs to the user whose relay topic this is.
    if socket.assigns.user_id == relay_user_id do
      Tabletop.Telemetry.camera_relay_join(:ok)
      send(self(), :after_join)
      {:ok, assign(socket, :relay_user_id, relay_user_id)}
    else
      Tabletop.Telemetry.camera_relay_join(:unauthorized)
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    %{relay_user_id: relay_user_id, socket_kind: socket_kind} = socket.assigns

    # One desktop and one phone. Signalling here is the same unaddressed
    # `broadcast_from!` fan-out as the game topic, so a third socket breaks it
    # the same way — but unlike a game, both ends belong to the same user, so
    # the seat is keyed by which end of the relay this is. A second desktop tab
    # evicts the first and leaves the phone alone. See TabletopWeb.ChannelSeat.
    ChannelSeat.claim(seat(relay_user_id, socket_kind))

    group = relay_group(relay_user_id)
    has_peer = :pg.get_members(:game_channels, group) != []
    :pg.join(:game_channels, group, self())

    broadcast_from!(socket, "peer_joined", %{})

    if has_peer do
      push(socket, "peer_exists", %{})
    end

    {:noreply, socket}
  end

  def handle_info(:superseded, socket) do
    # A newer socket for this end of the relay took the seat. Tell the client,
    # then stand down; `terminate/2` withholds `peer_left` so the other end
    # keeps the connection its replacement is about to renegotiate.
    push(socket, "superseded", %{})
    {:stop, :normal, assign(socket, :superseded, true)}
  end

  @impl true
  def handle_in("offer", %{"sdp" => sdp}, socket) do
    Tabletop.Telemetry.camera_relay_signal(:offer)
    broadcast_from!(socket, "offer", %{sdp: sdp})
    {:noreply, socket}
  end

  def handle_in("answer", %{"sdp" => sdp}, socket) do
    Tabletop.Telemetry.camera_relay_signal(:answer)
    broadcast_from!(socket, "answer", %{sdp: sdp})
    {:noreply, socket}
  end

  def handle_in("ice_candidate", %{"candidate" => candidate}, socket) do
    Tabletop.Telemetry.camera_relay_signal(:ice_candidate)
    broadcast_from!(socket, "ice_candidate", %{candidate: candidate})
    {:noreply, socket}
  end

  def handle_in(event, _payload, socket) do
    Logger.warning(
      "CameraRelayChannel: ignoring unexpected event #{inspect(event)} on #{socket.topic}"
    )

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # terminate/2 is still invoked when join/3 returns {:error, _}, so the
    # relay assigns may never have been set. Only clean up if we actually
    # joined the relay group.
    case socket.assigns do
      %{relay_user_id: relay_user_id, socket_kind: socket_kind} ->
        ChannelSeat.release(seat(relay_user_id, socket_kind))
        :pg.leave(:game_channels, relay_group(relay_user_id), self())

        if !socket.assigns[:superseded] do
          broadcast_from!(socket, "peer_left", %{})
        end

      _ ->
        :ok
    end

    :ok
  end

  defp relay_group(relay_user_id), do: {:camera_relay, relay_user_id}

  # `socket_kind` is `:user` for the desktop and `:phone` for the phone-camera
  # page — see TabletopWeb.UserSocket.
  defp seat(relay_user_id, socket_kind), do: {:camera_relay_seat, relay_user_id, socket_kind}
end
