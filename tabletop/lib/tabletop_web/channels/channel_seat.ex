defmodule TabletopWeb.ChannelSeat do
  @moduledoc """
  At-most-one-socket-per-seat guard for the WebRTC signalling channels.

  `TabletopWeb.GameChannel` and `TabletopWeb.CameraRelayChannel` both signal
  with a bare `broadcast_from!` fan-out: an offer, answer or ICE candidate goes
  to *every* other socket on the topic, and nothing in the payload names which
  peer it was meant for. That is correct for exactly two sockets and wrong for
  three, and a second browser tab is enough to make it three. `peer_joined`
  then reaches both existing sockets so both re-offer, each description crosses
  to a socket it was not addressed to, and every arriving offer runs
  `_createPeerConnection`, which closes the live connection before building a
  new one. The exchange never converges; it settles with the video dead on at
  least one side and no further `peer_joined` to recover from.

  Rather than teach the signalling layer to address peers, this preserves the
  invariant it already assumes: one socket per seat. A *seat* is whatever makes
  a participant unique on a topic — `{game, user}` for a game, `{user, end of
  the relay}` for a camera relay, since a relay topic legitimately holds two
  sockets belonging to the same user (the desktop and the phone).

  Claiming a seat evicts the previous holder and **waits for it to exit**. The
  wait is the point. Eviction has to finish before the newcomer broadcasts
  `peer_joined`, or the socket being evicted answers the offer its own
  replacement provoked and puts a third description on the wire — precisely the
  race this exists to remove.

  One window stays open: two sockets claiming the same seat in the microseconds
  between the `:pg.get_members/2` below and the `:pg.join/3` after it each see
  an empty seat, and both sit down. That needs two tabs to join within the same
  instant, and it degrades to the pre-existing behaviour rather than to
  something worse — reloading either tab settles it.
  """

  require Logger

  @scope :game_channels

  # A channel that has not shut down by now is wedged or already gone. Joining
  # anyway beats refusing the newcomer a seat over a predecessor that may not
  # exist.
  @evict_timeout_ms 5_000

  @doc """
  Takes `seat` for the calling process, evicting any previous holder and
  waiting for it to exit first.

  Returns the number of sockets evicted.
  """
  def claim(seat) do
    evicted =
      @scope
      |> :pg.get_members(seat)
      |> Enum.reject(&(&1 == self()))
      |> Enum.map(&evict(&1, seat))
      |> Enum.count(& &1)

    :pg.join(@scope, seat, self())

    evicted
  end

  @doc """
  Gives up `seat`. Safe to call from a process that never claimed one — `:pg`
  answers `:not_joined` rather than raising.
  """
  def release(seat), do: :pg.leave(@scope, seat, self())

  @doc """
  Whether a channel terminating for `reason` should announce `peer_left` to the
  rest of the topic.

  Two shutdowns are not departures, and announcing either tears down a peer
  connection that nothing is left to rebuild:

    * a **superseded** socket's replacement is already on the topic and about
      to renegotiate, so from the other side nobody left;
    * a **draining** socket is going down with the node. The media it signalled
      into being flows peer-to-peer and survives the server disappearing
      untouched, and the client reconnects on its own — so without this a
      deploy drops the video of whichever player is still connected when the
      other's socket drains, for a restart their connection never depended on.

  Phoenix stops a drained socket with `{:shutdown, :draining}` and the channel
  inherits that exact reason. A bare `:shutdown` is the same event arriving
  without the drainer — the transport being shut down under the channel — and
  means the same thing here.
  """
  def announce_departure?(reason, socket) do
    !socket.assigns[:superseded] and reason not in [:shutdown, {:shutdown, :draining}]
  end

  # Asks `pid` to stand down and blocks until it does. `:superseded` is sent
  # before the caller broadcasts `peer_joined`, and mailboxes are FIFO, so the
  # evicted channel stops without ever seeing the newcomer's announcement.
  defp evict(pid, seat) do
    ref = Process.monitor(pid)
    send(pid, :superseded)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        true
    after
      @evict_timeout_ms ->
        Process.demonitor(ref, [:flush])

        Logger.warning(
          "ChannelSeat: #{inspect(pid)} did not release #{inspect(seat)} within " <>
            "#{@evict_timeout_ms}ms; claiming anyway"
        )

        false
    end
  end
end
