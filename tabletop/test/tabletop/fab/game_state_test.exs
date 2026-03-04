defmodule Tabletop.Fab.GameStateTest do
  use ExUnit.Case, async: true

  alias Tabletop.Fab.GameState

  describe "new/0" do
    test "returns default state with 40 life" do
      state = GameState.new()
      assert state.my.life == 40
      assert state.opponent.life == 40
    end

    test "returns default state with all toggles false" do
      state = GameState.new()
      assert state.my.physical.active == false
      assert state.my.arcane.active == false
      assert state.my.goagain == false
    end

    test "returns default state with empty effects" do
      state = GameState.new()
      assert state.my.effects == %{}
      assert state.opponent.effects == %{}
    end

    test "returns default state with zero damage" do
      state = GameState.new()
      assert state.my.physical.damage == 0
      assert state.my.arcane.damage == 0
    end
  end

  describe "toggle_damage/2" do
    test "toggles physical from false to true" do
      state = GameState.new()

      assert {:ok, new_state, {:damage_toggled, :physical, true}} =
               GameState.toggle_damage(state, :physical)

      assert new_state.my.physical.active == true
    end

    test "toggles physical from true to false" do
      state = GameState.new()
      {:ok, state, _} = GameState.toggle_damage(state, :physical)

      assert {:ok, new_state, {:damage_toggled, :physical, false}} =
               GameState.toggle_damage(state, :physical)

      assert new_state.my.physical.active == false
    end

    test "toggles arcane" do
      state = GameState.new()

      assert {:ok, new_state, {:damage_toggled, :arcane, true}} =
               GameState.toggle_damage(state, :arcane)

      assert new_state.my.arcane.active == true
    end

    test "returns error for invalid type" do
      state = GameState.new()
      assert {:error, :invalid_damage_type} = GameState.toggle_damage(state, :fire)
    end

    test "does not affect opponent state" do
      state = GameState.new()
      {:ok, new_state, _} = GameState.toggle_damage(state, :physical)
      assert new_state.opponent == state.opponent
    end
  end

  describe "change_damage/3" do
    test "increments physical damage by 1" do
      state = GameState.new()

      assert {:ok, new_state, {:damage_changed, :physical, 1}} =
               GameState.change_damage(state, :physical, 1)

      assert new_state.my.physical.damage == 1
    end

    test "decrements physical damage by 1" do
      state = GameState.new()
      {:ok, state, _} = GameState.change_damage(state, :physical, 3)

      assert {:ok, new_state, {:damage_changed, :physical, 2}} =
               GameState.change_damage(state, :physical, -1)

      assert new_state.my.physical.damage == 2
    end

    test "clamps damage at 0" do
      state = GameState.new()

      assert {:ok, new_state, {:damage_changed, :physical, 0}} =
               GameState.change_damage(state, :physical, -5)

      assert new_state.my.physical.damage == 0
    end

    test "works with arcane damage" do
      state = GameState.new()

      assert {:ok, new_state, {:damage_changed, :arcane, 3}} =
               GameState.change_damage(state, :arcane, 3)

      assert new_state.my.arcane.damage == 3
    end

    test "returns error for invalid type" do
      state = GameState.new()
      assert {:error, :invalid_damage_type} = GameState.change_damage(state, :fire, 1)
    end
  end

  describe "toggle_goagain/1" do
    test "toggles from false to true" do
      state = GameState.new()
      assert {:ok, new_state, {:goagain_toggled, true}} = GameState.toggle_goagain(state)
      assert new_state.my.goagain == true
    end

    test "toggles from true to false" do
      state = GameState.new()
      {:ok, state, _} = GameState.toggle_goagain(state)
      assert {:ok, new_state, {:goagain_toggled, false}} = GameState.toggle_goagain(state)
      assert new_state.my.goagain == false
    end
  end

  describe "toggle_effect/2" do
    test "toggles a valid abilities" do
      state = GameState.new()

      assert {:ok, new_state, {:effect_toggled, "Dominate", true}} =
               GameState.toggle_effect(state, "Dominate")

      assert new_state.my.effects["Dominate"] == true
    end

    test "toggles a valid on-hit effect" do
      state = GameState.new()

      assert {:ok, new_state, {:effect_toggled, "Mark", true}} =
               GameState.toggle_effect(state, "Mark")

      assert new_state.my.effects["Mark"] == true
    end

    test "toggles from true back to false" do
      state = GameState.new()
      {:ok, state, _} = GameState.toggle_effect(state, "Dominate")

      assert {:ok, new_state, {:effect_toggled, "Dominate", false}} =
               GameState.toggle_effect(state, "Dominate")

      assert new_state.my.effects["Dominate"] == false
    end

    test "returns error for unknown effect" do
      state = GameState.new()
      assert {:error, :invalid_effect} = GameState.toggle_effect(state, "Nonexistent")
    end
  end

  describe "change_life/2" do
    test "increments life by 1" do
      state = GameState.new()
      assert {:ok, new_state, {:life_changed, 41}} = GameState.change_life(state, 1)
      assert new_state.my.life == 41
    end

    test "decrements life by 1" do
      state = GameState.new()
      assert {:ok, new_state, {:life_changed, 39}} = GameState.change_life(state, -1)
      assert new_state.my.life == 39
    end

    test "allows life to go negative" do
      state = GameState.new()
      assert {:ok, new_state, {:life_changed, -10}} = GameState.change_life(state, -50)
      assert new_state.my.life == -10
    end
  end

  describe "reset_chain/1" do
    test "resets damage, toggles, and effects but preserves life" do
      state = GameState.new()
      {:ok, state, _} = GameState.change_life(state, -5)
      {:ok, state, _} = GameState.toggle_damage(state, :physical)
      {:ok, state, _} = GameState.change_damage(state, :physical, 3)
      {:ok, state, _} = GameState.toggle_goagain(state)
      {:ok, state, _} = GameState.toggle_effect(state, "Dominate")

      assert {:ok, new_state, :chain_reset} = GameState.reset_chain(state)

      assert new_state.my.life == 35
      assert new_state.my.physical.active == false
      assert new_state.my.physical.damage == 0
      assert new_state.my.arcane.active == false
      assert new_state.my.arcane.damage == 0
      assert new_state.my.goagain == false
      assert new_state.my.effects == %{}
    end

    test "does not affect opponent state" do
      state = GameState.new()
      {:ok, state, _} = GameState.toggle_damage(state, :physical)
      {:ok, new_state, _} = GameState.reset_chain(state)
      assert new_state.opponent == state.opponent
    end
  end

  describe "apply_opponent_update/2" do
    test "applies damage_toggled" do
      state = GameState.new()
      new_state = GameState.apply_opponent_update(state, {:damage_toggled, :physical, true})
      assert new_state.opponent.physical.active == true
      assert new_state.my == state.my
    end

    test "applies damage_changed" do
      state = GameState.new()
      new_state = GameState.apply_opponent_update(state, {:damage_changed, :arcane, 5})
      assert new_state.opponent.arcane.damage == 5
      assert new_state.my == state.my
    end

    test "applies goagain_toggled" do
      state = GameState.new()
      new_state = GameState.apply_opponent_update(state, {:goagain_toggled, true})
      assert new_state.opponent.goagain == true
      assert new_state.my == state.my
    end

    test "applies effect_toggled" do
      state = GameState.new()
      new_state = GameState.apply_opponent_update(state, {:effect_toggled, "Frostbite", true})
      assert new_state.opponent.effects["Frostbite"] == true
      assert new_state.my == state.my
    end

    test "applies life_changed" do
      state = GameState.new()
      new_state = GameState.apply_opponent_update(state, {:life_changed, 35})
      assert new_state.opponent.life == 35
      assert new_state.my == state.my
    end

    test "applies chain_reset preserving life" do
      state = GameState.new()
      state = GameState.apply_opponent_update(state, {:damage_toggled, :physical, true})
      state = GameState.apply_opponent_update(state, {:damage_changed, :physical, 3})
      state = GameState.apply_opponent_update(state, {:life_changed, 35})

      new_state = GameState.apply_opponent_update(state, :chain_reset)

      assert new_state.opponent.life == 35
      assert new_state.opponent.physical.active == false
      assert new_state.opponent.physical.damage == 0
      assert new_state.my == state.my
    end
  end
end
