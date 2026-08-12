defmodule TabletopWeb.ChannelSeatTest do
  # Seats are namespaced per test with a unique integer, so concurrent tests
  # never contend for the same `:pg` group.
  use ExUnit.Case, async: true

  alias TabletopWeb.ChannelSeat

  setup do
    %{seat: {:test_seat, System.unique_integer([:positive])}}
  end

  describe "claim/1" do
    test "takes an empty seat without evicting anyone", %{seat: seat} do
      {pid, evicted} = seat_holder(seat)

      assert evicted == 0
      assert :pg.get_members(:game_channels, seat) == [pid]
    end

    test "evicts the previous holder and returns only once it has exited", %{seat: seat} do
      {first, 0} = seat_holder(seat)

      {second, evicted} = seat_holder(seat)

      assert evicted == 1
      # `claim/1` returned already, so the wait for the predecessor to exit
      # happened inside it — which is what keeps the evicted socket from
      # answering the `peer_joined` its own replacement is about to broadcast.
      refute Process.alive?(first)
      assert :pg.get_members(:game_channels, seat) == [second]
    end

    test "asks the previous holder to stand down rather than killing it", %{seat: seat} do
      {first, 0} = seat_holder(seat)

      seat_holder(seat)

      assert_receive {:stood_down, ^first}
    end

    test "does not block on a holder that is already gone", %{seat: seat} do
      {first, 0} = seat_holder(seat)
      Process.exit(first, :kill)

      # `:pg` reaps a dead member asynchronously, so the seat may still list
      # `first` here. Monitoring a dead pid yields an immediate `:DOWN`, so the
      # claim must not wait out the eviction timeout.
      {second, _evicted} = seat_holder(seat)

      assert second in :pg.get_members(:game_channels, seat)
    end
  end

  describe "release/1" do
    test "frees the seat for the next claimant", %{seat: seat} do
      {pid, 0} = seat_holder(seat)

      send(pid, :release)
      assert_receive {:released, ^pid}

      assert :pg.get_members(:game_channels, seat) == []
    end

    test "is safe for a process that never claimed the seat", %{seat: seat} do
      assert ChannelSeat.release(seat) == :not_joined
    end
  end

  # --- Helpers ---

  # Spawns a process that claims `seat` and then stands in for a channel: on
  # `:superseded` it gives up the seat and exits, exactly as the channels'
  # `handle_info/2` + `terminate/2` pair does.
  defp seat_holder(seat) do
    test_pid = self()

    pid =
      spawn(fn ->
        evicted = ChannelSeat.claim(seat)
        send(test_pid, {:claimed, self(), evicted})
        hold(seat, test_pid)
      end)

    assert_receive {:claimed, ^pid, evicted}
    on_exit(fn -> Process.exit(pid, :kill) end)

    {pid, evicted}
  end

  defp hold(seat, test_pid) do
    receive do
      :superseded ->
        ChannelSeat.release(seat)
        send(test_pid, {:stood_down, self()})

      :release ->
        ChannelSeat.release(seat)
        send(test_pid, {:released, self()})
        hold(seat, test_pid)
    end
  end
end
