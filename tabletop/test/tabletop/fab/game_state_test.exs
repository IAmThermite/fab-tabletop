defmodule Tabletop.Fab.GameStateTest do
  use ExUnit.Case, async: true

  alias Tabletop.Fab.GameState

  describe "default_player/0" do
    test "returns default state with 40 life" do
      player = GameState.default_player()
      assert player.life == 40
    end

    test "returns default state with all toggles false" do
      player = GameState.default_player()
      assert player.physical.active == false
      assert player.arcane.active == false
      assert player.goagain == false
    end

    test "returns default state with empty effects" do
      player = GameState.default_player()
      assert player.effects == %{}
    end

    test "returns default state with zero damage" do
      player = GameState.default_player()
      assert player.physical.damage == 0
      assert player.arcane.damage == 0
    end
  end

  describe "toggle_damage/2" do
    test "toggles physical from false to true" do
      player = GameState.default_player()

      assert {:ok, new_player, {:damage_toggled, :physical, true}} =
               GameState.toggle_damage(player, :physical)

      assert new_player.physical.active == true
    end

    test "toggles physical from true to false" do
      {:ok, player, _} = GameState.toggle_damage(GameState.default_player(), :physical)

      assert {:ok, new_player, {:damage_toggled, :physical, false}} =
               GameState.toggle_damage(player, :physical)

      assert new_player.physical.active == false
    end

    test "toggles arcane" do
      player = GameState.default_player()

      assert {:ok, new_player, {:damage_toggled, :arcane, true}} =
               GameState.toggle_damage(player, :arcane)

      assert new_player.arcane.active == true
    end

    test "returns error for invalid type" do
      assert {:error, :invalid_damage_type} =
               GameState.toggle_damage(GameState.default_player(), :fire)
    end

    test "adds a tile position when toggling on" do
      {:ok, new_player, _} = GameState.toggle_damage(GameState.default_player(), :physical)
      assert Map.has_key?(new_player.tile_positions, "physical")
    end

    test "removes the tile position when toggling off" do
      {:ok, player, _} = GameState.toggle_damage(GameState.default_player(), :physical)
      {:ok, new_player, _} = GameState.toggle_damage(player, :physical)
      refute Map.has_key?(new_player.tile_positions, "physical")
    end
  end

  describe "change_damage/3" do
    test "increments physical damage by 1" do
      assert {:ok, new_player, {:damage_changed, :physical, 1}} =
               GameState.change_damage(GameState.default_player(), :physical, 1)

      assert new_player.physical.damage == 1
    end

    test "decrements physical damage by 1" do
      {:ok, player, _} = GameState.change_damage(GameState.default_player(), :physical, 3)

      assert {:ok, new_player, {:damage_changed, :physical, 2}} =
               GameState.change_damage(player, :physical, -1)

      assert new_player.physical.damage == 2
    end

    test "clamps damage at 0" do
      assert {:ok, new_player, {:damage_changed, :physical, 0}} =
               GameState.change_damage(GameState.default_player(), :physical, -5)

      assert new_player.physical.damage == 0
    end

    test "works with arcane damage" do
      assert {:ok, new_player, {:damage_changed, :arcane, 3}} =
               GameState.change_damage(GameState.default_player(), :arcane, 3)

      assert new_player.arcane.damage == 3
    end

    test "returns error for invalid type" do
      assert {:error, :invalid_damage_type} =
               GameState.change_damage(GameState.default_player(), :fire, 1)
    end
  end

  describe "toggle_goagain/1" do
    test "toggles from false to true" do
      assert {:ok, new_player, {:goagain_toggled, true}} =
               GameState.toggle_goagain(GameState.default_player())

      assert new_player.goagain == true
    end

    test "toggles from true to false" do
      {:ok, player, _} = GameState.toggle_goagain(GameState.default_player())

      assert {:ok, new_player, {:goagain_toggled, false}} = GameState.toggle_goagain(player)
      assert new_player.goagain == false
    end
  end

  describe "toggle_effect/3" do
    test "toggles a valid ability" do
      assert {:ok, new_player, {:effect_toggled, "ability", "Dominate", true}} =
               GameState.toggle_effect(GameState.default_player(), "ability", "Dominate")

      assert new_player.effects["ability:Dominate"] == true
    end

    test "toggles a valid on-hit effect" do
      assert {:ok, new_player, {:effect_toggled, "on_hit", "Mark", true}} =
               GameState.toggle_effect(GameState.default_player(), "on_hit", "Mark")

      assert new_player.effects["on_hit:Mark"] == true
    end

    test "toggles from true back to false" do
      {:ok, player, _} =
        GameState.toggle_effect(GameState.default_player(), "ability", "Dominate")

      assert {:ok, new_player, {:effect_toggled, "ability", "Dominate", false}} =
               GameState.toggle_effect(player, "ability", "Dominate")

      assert new_player.effects["ability:Dominate"] == false
    end

    test "ability and on-hit are namespaced separately" do
      player = GameState.default_player()
      {:ok, player, _} = GameState.toggle_effect(player, "ability", "Dominate")
      {:ok, player, _} = GameState.toggle_effect(player, "on_hit", "Mark")

      assert player.effects["ability:Dominate"] == true
      assert player.effects["on_hit:Mark"] == true
      assert Map.get(player.effects, "Dominate") == nil
      assert Map.get(player.effects, "Mark") == nil
    end

    test "returns error for unknown effect" do
      assert {:error, :invalid_effect} =
               GameState.toggle_effect(GameState.default_player(), "ability", "Nonexistent")
    end

    test "returns error for unknown category" do
      assert {:error, :invalid_effect} =
               GameState.toggle_effect(GameState.default_player(), "bogus", "Dominate")
    end
  end

  describe "change_life/2" do
    test "increments life by 1" do
      assert {:ok, new_player, {:life_changed, 41}} =
               GameState.change_life(GameState.default_player(), 1)

      assert new_player.life == 41
    end

    test "decrements life by 1" do
      assert {:ok, new_player, {:life_changed, 39}} =
               GameState.change_life(GameState.default_player(), -1)

      assert new_player.life == 39
    end

    test "does not allow life to go negative" do
      assert {:ok, new_player, {:life_changed, 0}} =
               GameState.change_life(GameState.default_player(), -50)

      assert new_player.life == 0
    end
  end

  describe "move_tile/4" do
    test "records tile position clamped to [0, 100]" do
      {:ok, new_player, {:tile_moved, "foo", 50.0, 100.0}} =
        GameState.move_tile(GameState.default_player(), "foo", 50.0, 250.0)

      assert new_player.tile_positions["foo"] == %{x: 50.0, y: 100.0}
    end
  end

  describe "reset_chain/1" do
    test "resets damage, toggles, and effects but preserves life" do
      player = GameState.default_player()
      {:ok, player, _} = GameState.change_life(player, -5)
      {:ok, player, _} = GameState.toggle_damage(player, :physical)
      {:ok, player, _} = GameState.change_damage(player, :physical, 3)
      {:ok, player, _} = GameState.toggle_goagain(player)
      {:ok, player, _} = GameState.toggle_effect(player, "ability", "Dominate")

      assert {:ok, new_player, :chain_reset} = GameState.reset_chain(player)

      assert new_player.life == 35
      assert new_player.physical.active == false
      assert new_player.physical.damage == 0
      assert new_player.arcane.active == false
      assert new_player.arcane.damage == 0
      assert new_player.goagain == false
      assert new_player.effects == %{}
      assert new_player.tile_positions == %{}
    end
  end

  describe "set_media/3" do
    test "defaults mic and camera to enabled" do
      player = GameState.default_player()
      assert player.mic == true
      assert player.camera == true
    end

    test "sets the mic flag and returns a media_changed delta" do
      assert {:ok, new_player, {:media_changed, :mic, false}} =
               GameState.set_media(GameState.default_player(), :mic, false)

      assert new_player.mic == false
      assert new_player.camera == true
    end

    test "sets the camera flag and returns a media_changed delta" do
      assert {:ok, new_player, {:media_changed, :camera, false}} =
               GameState.set_media(GameState.default_player(), :camera, false)

      assert new_player.camera == false
      assert new_player.mic == true
    end

    test "rejects unknown kinds" do
      assert {:error, :invalid_media} =
               GameState.set_media(GameState.default_player(), :speaker, true)
    end

    test "rejects non-boolean values" do
      assert {:error, :invalid_media} =
               GameState.set_media(GameState.default_player(), :mic, "true")
    end
  end
end
