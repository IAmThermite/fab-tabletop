defmodule Tabletop.Fab.GameState do
  @moduledoc """
  Encapsulates the in-memory game state for a single player's view

  Each player maintains their own state (life, damage toggles, effects)
  and a view of their opponent's state received via PubSub.
  """

  alias Tabletop.Fab.Effects

  @valid_damage_types [:physical, :arcane]
  @min_damage 0

  @default_player %{
    life: 40,
    physical: %{active: false, damage: 0},
    arcane: %{active: false, damage: 0},
    goagain: false,
    effects: %{}
  }

  defstruct my: @default_player, opponent: @default_player

  def new, do: %__MODULE__{}

  # Local player actions

  def toggle_damage(%__MODULE__{} = state, type) when type in @valid_damage_types do
    new_val = !state.my[type].active
    new_my = put_in(state.my, [type, :active], new_val)
    {:ok, %{state | my: new_my}, {:damage_toggled, type, new_val}}
  end

  def toggle_damage(_, _), do: {:error, :invalid_damage_type}

  def change_damage(%__MODULE__{} = state, type, delta) when type in @valid_damage_types do
    new_val = max(@min_damage, state.my[type].damage + delta)
    new_my = put_in(state.my, [type, :damage], new_val)
    {:ok, %{state | my: new_my}, {:damage_changed, type, new_val}}
  end

  def change_damage(_, _, _), do: {:error, :invalid_damage_type}

  def toggle_goagain(%__MODULE__{} = state) do
    new_val = !state.my.goagain
    {:ok, %{state | my: %{state.my | goagain: new_val}}, {:goagain_toggled, new_val}}
  end

  def toggle_effect(%__MODULE__{} = state, effect_name) do
    if valid_effect?(effect_name) do
      new_val = !Map.get(state.my.effects, effect_name, false)
      new_effects = Map.put(state.my.effects, effect_name, new_val)
      new_state = %{state | my: %{state.my | effects: new_effects}}
      {:ok, new_state, {:effect_toggled, effect_name, new_val}}
    else
      {:error, :invalid_effect}
    end
  end

  def change_life(%__MODULE__{} = state, delta) do
    new_life = state.my.life + delta
    {:ok, %{state | my: %{state.my | life: new_life}}, {:life_changed, new_life}}
  end

  def reset_chain(%__MODULE__{} = state) do
    default = %__MODULE__{}
    reset_my = %{default.my | life: state.my.life}
    {:ok, %{state | my: reset_my}, :chain_reset}
  end

  # --- Opponent update application ---

  def apply_opponent_update(%__MODULE__{} = state, {:damage_toggled, type, value}) do
    new_opponent = put_in(state.opponent, [type, :active], value)
    %{state | opponent: new_opponent}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:damage_changed, type, value}) do
    new_opponent = put_in(state.opponent, [type, :damage], value)
    %{state | opponent: new_opponent}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:goagain_toggled, value}) do
    %{state | opponent: %{state.opponent | goagain: value}}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:effect_toggled, name, value}) do
    new_effects = Map.put(state.opponent.effects, name, value)
    %{state | opponent: %{state.opponent | effects: new_effects}}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:life_changed, value}) do
    %{state | opponent: %{state.opponent | life: value}}
  end

  def apply_opponent_update(%__MODULE__{} = state, :chain_reset) do
    default = %__MODULE__{}
    reset_opponent = %{default.opponent | life: state.opponent.life}
    %{state | opponent: reset_opponent}
  end

  defp valid_effect?(name) do
    all_effects = Map.merge(Effects.conditions(), Effects.on_hit_effects())
    Enum.any?(all_effects, fn {_key, effect} -> effect[:name] == name end)
  end
end
