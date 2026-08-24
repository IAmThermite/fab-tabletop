defmodule TabletopWeb.CameraRelayChannel do
  use Phoenix.Channel

  require Logger

  alias TabletopWeb.ChannelSeat

  intercept(["peer_joined"])

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

      # The phone offers, because it is the end that sends: its offer carries
      # the camera tracks the desktop is waiting for. That it is fixed is the
      # part that matters — see `request_offer/1`.
      {:ok,
       socket
       |> assign(:relay_user_id, relay_user_id)
       |> assign(:offerer, socket.assigns.socket_kind == :phone)}
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
      request_offer(socket)
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
  def handle_out("peer_joined", payload, socket) do
    push(socket, "peer_joined", payload)
    request_offer(socket)
    {:noreply, socket}
  end

  # Asks this socket for an offer, if it is the end that offers. Same reasoning
  # as `TabletopWeb.GameChannel.request_offer/1`: a desktop and a phone can
  # rejoin in the same instant — a deploy does exactly that — and both would
  # find the group empty by the check-then-act in `after_join` and announce
  # themselves. If arriving were reason enough to offer, both would, and the two
  # offers would close each other's connections with nothing left to retrigger
  # either.
  defp request_offer(socket) do
    if socket.assigns.offerer, do: push(socket, "make_offer", %{})
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
  def terminate(reason, socket) do
    # terminate/2 is still invoked when join/3 returns {:error, _}, so the
    # relay assigns may never have been set. Only clean up if we actually
    # joined the relay group.
    case socket.assigns do
      %{relay_user_id: relay_user_id, socket_kind: socket_kind} ->
        ChannelSeat.release(seat(relay_user_id, socket_kind))
        :pg.leave(:game_channels, relay_group(relay_user_id), self())

        # Draining counts the same as being superseded here: the phone keeps
        # sending to the desktop across a restart, so announcing a departure
        # would drop the board camera for a deploy it never noticed. See
        # `ChannelSeat.announce_departure?/2`.
        if ChannelSeat.announce_departure?(reason, socket) do
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
