defmodule TabletopWeb.CameraRelayChannel do
  use Phoenix.Channel

  @impl true
  def join("camera_relay:" <> token, _payload, socket) do
    case Phoenix.Token.verify(socket, "camera relay", token, max_age: 3600) do
      {:ok, _user_id} ->
        send(self(), :after_join)
        {:ok, assign(socket, :relay_token, token)}

      {:error, _reason} ->
        {:error, %{reason: "invalid_token"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    group = relay_group(socket.assigns.relay_token)
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
    :pg.leave(:game_channels, relay_group(socket.assigns.relay_token), self())
    broadcast_from!(socket, "peer_left", %{})
    :ok
  end

  defp relay_group(token), do: {:camera_relay, token}
end
