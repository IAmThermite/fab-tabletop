defmodule TabletopWeb.CameraRelayChannel do
  use Phoenix.Channel

  @impl true
  def join("camera_relay:" <> relay_user_id, _payload, socket) do
    # The relay topic is keyed by user_id, which is stable across page mounts.
    # (The signed token can't be the topic — it's regenerated on every mount,
    # so the phone and desktop would land in different topics.) The socket is
    # already authenticated in UserSocket; here we just confirm the joining
    # socket belongs to the user whose relay topic this is.
    if socket.assigns.user_id == relay_user_id do
      send(self(), :after_join)
      {:ok, assign(socket, :relay_user_id, relay_user_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    group = relay_group(socket.assigns.relay_user_id)
    has_peer = :pg.get_members(:game_channels, group) != []
    :pg.join(:game_channels, group, self())

    broadcast_from!(socket, "peer_joined", %{})

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
    # terminate/2 is still invoked when join/3 returns {:error, _}, so the
    # relay assigns may never have been set. Only clean up if we actually
    # joined the relay group.
    case socket.assigns do
      %{relay_user_id: relay_user_id} ->
        :pg.leave(:game_channels, relay_group(relay_user_id), self())
        broadcast_from!(socket, "peer_left", %{})

      _ ->
        :ok
    end

    :ok
  end

  defp relay_group(relay_user_id), do: {:camera_relay, relay_user_id}
end
