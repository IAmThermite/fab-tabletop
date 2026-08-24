defmodule TabletopWeb.GameChannel do
  use Phoenix.Channel

  require Logger

  alias Tabletop.Repo
  alias Tabletop.Games.Game
  alias TabletopWeb.ChannelSeat

  intercept(["peer_joined"])

  @impl true
  def join("game:" <> game_id, _payload, socket) do
    user_id = socket.assigns.user_id

    case Repo.get(Game, game_id) do
      # Which player offers is arbitrary; that it is decided here, once, is not
      # — see `request_offer/1`. The game's creator offers, the player who
      # joined their game answers.
      %Game{user_id: ^user_id} ->
        send(self(), :after_join)
        {:ok, joined(socket, game_id, true)}

      %Game{user2_id: ^user_id} ->
        send(self(), :after_join)
        {:ok, joined(socket, game_id, false)}

      _other ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  defp joined(socket, game_id, offerer?) do
    socket |> assign(:game_id, game_id) |> assign(:offerer, offerer?)
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

    # Notify existing peers that we joined. Only the offerer acts on it —
    # `handle_out/3` below.
    broadcast_from!(socket, "peer_joined", %{user_id: user_id})

    # If we're the second joiner, the first joiner's broadcast was lost (we
    # weren't listening yet), so nothing above told us they are there.
    if has_peer do
      push(socket, "peer_exists", %{})
      request_offer(socket)
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
  def handle_out("peer_joined", payload, socket) do
    push(socket, "peer_joined", payload)
    request_offer(socket)
    {:noreply, socket}
  end

  # Asks this socket for an offer, if it is the side that offers.
  #
  # Exactly one side of the topic may answer a peer's arrival with an offer, and
  # the server picks which — the announcement itself cannot be the trigger. Both
  # players reconnect within the same instant after a deploy, and the `has_peer`
  # check in `after_join` is a check-then-act: both can find the group empty and
  # both then announce themselves. If arriving were reason enough to offer, both
  # would, each `_createPeerConnection` would close the connection its own offer
  # was made on, and the exchange would settle with the video dead on both sides
  # and nothing left to retrigger it. Nominating a fixed side makes the outcome
  # identical however the join order falls out.
  defp request_offer(socket) do
    if socket.assigns.offerer, do: push(socket, "make_offer", %{})
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
  def terminate(reason, %{assigns: %{game_id: game_id, user_id: user_id}} = socket) do
    ChannelSeat.release(seat(game_id, user_id))
    :pg.leave(:game_channels, game_group(game_id), self())

    # Being superseded or drained is not leaving, and saying it is would tear
    # down a connection the opponent is either about to have rebuilt or never
    # lost — see `ChannelSeat.announce_departure?/2`.
    if ChannelSeat.announce_departure?(reason, socket) do
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
