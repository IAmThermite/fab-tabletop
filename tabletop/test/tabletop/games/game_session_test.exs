defmodule Tabletop.Games.GameSessionTest do
  use ExUnit.Case, async: false

  alias Tabletop.Games.GameSession

  setup do
    game_id = System.unique_integer([:positive])
    game = %{id: game_id, user_id: 1001, user2_id: 1002}

    Phoenix.PubSub.subscribe(Tabletop.PubSub, "game_session:#{game_id}")
    :ok = GameSession.ensure_started(game)

    # Drain the init :session_reset broadcast we subscribed in time to see.
    receive do
      {:session_reset, _} -> :ok
    after
      50 -> :ok
    end

    on_exit(fn -> GameSession.stop(game_id) end)

    {:ok, game: game, game_id: game_id}
  end

  describe "ensure_started/1" do
    test "is idempotent", %{game: game} do
      assert :ok = GameSession.ensure_started(game)
      assert :ok = GameSession.ensure_started(game)
    end
  end

  describe "get_state/1" do
    test "returns default state for both users", %{game_id: game_id} do
      assert %{user1: user1, user2: user2} = GameSession.get_state(game_id)
      assert user1.life == 40
      assert user2.life == 40
    end
  end

  describe "apply_action/3" do
    test "routes actor's actions to their own side", %{game_id: game_id} do
      :ok = GameSession.apply_action(game_id, 1001, {:change_life, -5})
      assert %{user1: %{life: 35}, user2: %{life: 40}} = GameSession.get_state(game_id)

      :ok = GameSession.apply_action(game_id, 1002, {:change_life, -3})
      assert %{user1: %{life: 35}, user2: %{life: 37}} = GameSession.get_state(game_id)
    end

    test "broadcasts game_update with target side and actor id", %{game_id: game_id} do
      :ok = GameSession.apply_action(game_id, 1001, {:toggle_damage, :physical})

      assert_receive {:game_update, :user1, {:damage_toggled, :physical, true}, 1001}
    end

    test "move_tile routes to the named target side regardless of actor", %{game_id: game_id} do
      # user1 drags user2's tile
      :ok = GameSession.apply_action(game_id, 1001, {:move_tile, 1002, "arcane", 25.0, 30.0})

      assert %{user2: %{tile_positions: %{"arcane" => %{x: 25.0, y: 30.0}}}} =
               GameSession.get_state(game_id)

      assert_receive {:game_update, :user2, {:tile_moved, "arcane", 25.0, 30.0}, 1001}
    end

    test "returns error for unknown user", %{game_id: game_id} do
      assert {:error, :unknown_user} =
               GameSession.apply_action(game_id, 9999, {:change_life, 1})
    end

    test "returns error for unknown action shape", %{game_id: game_id} do
      assert {:error, :unknown_action} = GameSession.apply_action(game_id, 1001, :bogus)
    end

    test "propagates transform errors", %{game_id: game_id} do
      assert {:error, :invalid_damage_type} =
               GameSession.apply_action(game_id, 1001, {:toggle_damage, :fire})
    end
  end

  describe "init broadcasts :session_reset" do
    test "fires on (re)start with a default snapshot" do
      game_id = System.unique_integer([:positive])
      game = %{id: game_id, user_id: 2001, user2_id: 2002}

      Phoenix.PubSub.subscribe(Tabletop.PubSub, "game_session:#{game_id}")
      :ok = GameSession.ensure_started(game)

      assert_receive {:session_reset, %{user1: %{life: 40}, user2: %{life: 40}}}

      GameSession.stop(game_id)
    end
  end
end
