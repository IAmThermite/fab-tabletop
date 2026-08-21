defmodule Tabletop.Games.GameSessionPersistenceTest do
  @moduledoc """
  The session's state save runs in a supervised Task rather than inline, so it
  can't hold up the actions a player's clicks travel through. These cover what
  that must not break: the debounced write still lands, and a restarted session
  still reads its state back.

  The ordering guards around the async save (`terminate/2` waiting out an
  in-flight write, and `:save_state` re-arming rather than starting a second)
  are deliberately not covered here — locally the write finishes in well under a
  millisecond, so the window they protect can't be forced open without a test
  seam in the write path, and a test that can't fail is worse than none.
  """

  # Not async: the sandbox has to be in shared mode so the save Task (a
  # different process) can reach the connection.
  use Tabletop.DataCase, async: false

  import Tabletop.GamesFixtures
  import Tabletop.AccountsFixtures

  alias Tabletop.Games
  alias Tabletop.Games.GameSession

  setup do
    scope = user_scope_fixture()
    game = game_fixture(scope)

    :ok = GameSession.ensure_started(game)
    on_exit(fn -> GameSession.stop(game.id) end)

    %{game: game}
  end

  defp eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(25) && do_eventually(fun, deadline)
    end
  end

  test "the debounced save persists without blocking the session", %{game: game} do
    :ok = GameSession.apply_action(game.id, game.user_id, {:change_life, -7})

    # The session answers immediately — it never waits on the write.
    assert %{user1: %{life: 33}} = GameSession.get_state(game.id)

    assert eventually(fn ->
             match?(%{"user1" => %{"life" => 33}}, Games.get_game_state(game.id))
           end),
           "expected the debounced save to reach the database, got: " <>
             inspect(Games.get_game_state(game.id))
  end

  test "state survives a session restart", %{game: game} do
    :ok = GameSession.apply_action(game.id, game.user_id, {:change_life, -7})
    :ok = GameSession.apply_action(game.id, game.user_id, {:toggle_goagain})

    # Stops synchronously, so `terminate/2` has written the final snapshot —
    # waiting out any async save in flight — by the time this returns.
    :ok = GameSession.stop(game.id)
    :ok = GameSession.ensure_started(game)

    assert %{user1: %{life: 33, goagain: true}} = GameSession.get_state(game.id)
  end
end
