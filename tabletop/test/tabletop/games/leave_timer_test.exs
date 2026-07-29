defmodule Tabletop.Games.LeaveTimerTest do
  use Tabletop.DataCase, async: false

  import Tabletop.AccountsFixtures
  import Tabletop.GamesFixtures

  alias Tabletop.Games.Game
  alias Tabletop.Games.LeaveTimer

  setup do
    scope = user_scope_fixture()
    game = game_fixture(scope)
    %{scope: scope, game: game, user_id: scope.user.id}
  end

  describe "schedule_leave/3" do
    test "schedules a leave timer when the user has no live connection",
         %{scope: scope, game: game, user_id: user_id} do
      refute timer_scheduled?(game.id, user_id)

      assert :ok = LeaveTimer.schedule_leave(game.id, user_id, scope)

      assert timer_scheduled?(game.id, user_id)
      on_exit(fn -> LeaveTimer.cancel_leave(game.id, user_id) end)
    end

    test "does not schedule when the user already has a live connection",
         %{scope: scope, game: game, user_id: user_id} do
      # Simulates the page-refresh race: the reconnecting LiveView has already
      # mounted and registered before the old LiveView's terminate/2 runs.
      track_connection_in_process(game.id, user_id)

      assert :ok = LeaveTimer.schedule_leave(game.id, user_id, scope)

      refute timer_scheduled?(game.id, user_id)
    end
  end

  describe "cancel_leave/2" do
    test "stops a scheduled leave timer", %{scope: scope, game: game, user_id: user_id} do
      :ok = LeaveTimer.schedule_leave(game.id, user_id, scope)
      assert timer_scheduled?(game.id, user_id)

      assert :ok = LeaveTimer.cancel_leave(game.id, user_id)

      # The timer process is stopped synchronously, but the Registry clears its
      # entry asynchronously once it observes the process going down.
      eventually(fn -> not timer_scheduled?(game.id, user_id) end)
    end

    test "is a no-op when no timer is scheduled", %{game: game, user_id: user_id} do
      assert :ok = LeaveTimer.cancel_leave(game.id, user_id)
    end
  end

  describe "leave execution" do
    test "terminates the game when the user has not reconnected",
         %{scope: scope, game: game, user_id: user_id} do
      :ok = LeaveTimer.schedule_leave(game.id, user_id, scope)

      fire_timer(game.id, user_id)

      assert Repo.get!(Game, game.id).status == :finished
    end

    test "does not terminate the game when the user has reconnected",
         %{scope: scope, game: game, user_id: user_id} do
      # The disconnect schedules the timer...
      :ok = LeaveTimer.schedule_leave(game.id, user_id, scope)
      # ...then the user reconnects (e.g. finishes a page refresh) before it fires.
      track_connection_in_process(game.id, user_id)

      fire_timer(game.id, user_id)

      assert Repo.get!(Game, game.id).status == :waiting
    end
  end

  # --- Helpers ---

  defp timer_scheduled?(game_id, user_id) do
    Registry.lookup(Tabletop.Games.LeaveTimerRegistry, {game_id, user_id}) != []
  end

  # Retries `fun` until it returns a truthy value, for assertions that depend
  # on asynchronous bookkeeping (e.g. Registry reaping a `:via` name after the
  # timer process exits — there is no synchronous hook for that). Returns as
  # soon as the condition holds, so a generous attempt budget only affects the
  # (rare) failing path — 5s tolerates scheduler jitter under a loaded full-suite
  # run without slowing the happy path, where it typically succeeds in one pass.
  defp eventually(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> flunk("condition was not met in time")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  # Sends :execute_leave to the timer process to simulate the grace period
  # elapsing, then waits for it to finish handling the message and stop.
  defp fire_timer(game_id, user_id) do
    [{pid, _}] = Registry.lookup(Tabletop.Games.LeaveTimerRegistry, {game_id, user_id})
    ref = Process.monitor(pid)
    send(pid, :execute_leave)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  # Spawns a process that registers itself as a live connection (as a connected
  # GameLive.Show would) and stays alive for the duration of the test.
  defp track_connection_in_process(game_id, user_id) do
    test_pid = self()

    pid =
      spawn(fn ->
        LeaveTimer.track_connection(game_id, user_id)
        send(test_pid, :connection_tracked)
        Process.sleep(:infinity)
      end)

    assert_receive :connection_tracked
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
