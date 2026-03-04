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
    effects: %{},
    tile_positions: %{}
  }

  defstruct my: @default_player, opponent: @default_player

  def new, do: %__MODULE__{}

  # Local player actions

  def toggle_damage(%__MODULE__{} = state, type) when type in @valid_damage_types do
    new_val = !state.my[type].active
    new_my = put_in(state.my, [type, :active], new_val)
    tile_id = Atom.to_string(type)

    new_my =
      if new_val,
        do: ensure_tile_position(new_my, tile_id),
        else: %{new_my | tile_positions: Map.delete(new_my.tile_positions, tile_id)}

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
    new_my = %{state.my | goagain: new_val}

    new_my =
      if new_val,
        do: ensure_tile_position(new_my, "goagain"),
        else: %{new_my | tile_positions: Map.delete(new_my.tile_positions, "goagain")}

    {:ok, %{state | my: new_my}, {:goagain_toggled, new_val}}
  end

  def toggle_effect(%__MODULE__{} = state, effect_name) do
    if valid_effect?(effect_name) do
      new_val = !Map.get(state.my.effects, effect_name, false)
      new_effects = Map.put(state.my.effects, effect_name, new_val)
      new_my = %{state.my | effects: new_effects}

      new_my =
        if new_val,
          do: ensure_tile_position(new_my, effect_name),
          else: %{new_my | tile_positions: Map.delete(new_my.tile_positions, effect_name)}

      new_state = %{state | my: new_my}
      {:ok, new_state, {:effect_toggled, effect_name, new_val}}
    else
      {:error, :invalid_effect}
    end
  end

  def move_tile(%__MODULE__{} = state, tile_id, x, y)
      when is_binary(tile_id) and is_number(x) and is_number(y) do
    x = max(0.0, min(100.0, x / 1))
    y = max(0.0, min(100.0, y / 1))
    new_positions = Map.put(state.my.tile_positions, tile_id, %{x: x, y: y})
    new_my = %{state.my | tile_positions: new_positions}
    {:ok, %{state | my: new_my}, {:tile_moved, tile_id, x, y}}
  end

  def move_opponent_tile(%__MODULE__{} = state, tile_id, x, y)
      when is_binary(tile_id) and is_number(x) and is_number(y) do
    x = max(0.0, min(100.0, x / 1))
    y = max(0.0, min(100.0, y / 1))
    new_positions = Map.put(state.opponent.tile_positions, tile_id, %{x: x, y: y})
    new_opponent = %{state.opponent | tile_positions: new_positions}
    {:ok, %{state | opponent: new_opponent}, {:opponent_tile_moved, tile_id, x, y}}
  end

  def change_life(%__MODULE__{} = state, delta) do
    new_life = state.my.life + delta
    {:ok, %{state | my: %{state.my | life: new_life}}, {:life_changed, new_life}}
  end

  def reset_chain(%__MODULE__{} = state) do
    default = %__MODULE__{}
    reset_my = %{default.my | life: state.my.life, tile_positions: %{}}
    {:ok, %{state | my: reset_my}, :chain_reset}
  end

  # --- Opponent update application ---

  def apply_opponent_update(%__MODULE__{} = state, {:damage_toggled, type, value}) do
    new_opponent = put_in(state.opponent, [type, :active], value)
    tile_id = Atom.to_string(type)

    new_opponent =
      if value,
        do: ensure_tile_position(new_opponent, tile_id),
        else: %{new_opponent | tile_positions: Map.delete(new_opponent.tile_positions, tile_id)}

    %{state | opponent: new_opponent}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:damage_changed, type, value}) do
    new_opponent = put_in(state.opponent, [type, :damage], value)
    %{state | opponent: new_opponent}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:goagain_toggled, value}) do
    new_opponent = %{state.opponent | goagain: value}

    new_opponent =
      if value,
        do: ensure_tile_position(new_opponent, "goagain"),
        else: %{new_opponent | tile_positions: Map.delete(new_opponent.tile_positions, "goagain")}

    %{state | opponent: new_opponent}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:effect_toggled, name, value}) do
    new_effects = Map.put(state.opponent.effects, name, value)
    new_opponent = %{state.opponent | effects: new_effects}

    new_opponent =
      if value,
        do: ensure_tile_position(new_opponent, name),
        else: %{new_opponent | tile_positions: Map.delete(new_opponent.tile_positions, name)}

    %{state | opponent: new_opponent}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:life_changed, value}) do
    %{state | opponent: %{state.opponent | life: value}}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:tile_moved, tile_id, x, y}) do
    new_positions = Map.put(state.opponent.tile_positions, tile_id, %{x: x, y: y})
    %{state | opponent: %{state.opponent | tile_positions: new_positions}}
  end

  def apply_opponent_update(%__MODULE__{} = state, {:opponent_tile_moved, tile_id, x, y}) do
    new_positions = Map.put(state.my.tile_positions, tile_id, %{x: x, y: y})
    %{state | my: %{state.my | tile_positions: new_positions}}
  end

  def apply_opponent_update(%__MODULE__{} = state, :chain_reset) do
    default = %__MODULE__{}
    reset_opponent = %{default.opponent | life: state.opponent.life, tile_positions: %{}}
    %{state | opponent: reset_opponent}
  end

  defp valid_effect?(name) do
    all_effects = Map.merge(Effects.abilities(), Effects.on_hit_effects())
    Enum.any?(all_effects, fn {_key, effect} -> effect[:name] == name end)
  end

  defp ensure_tile_position(player, tile_id) do
    if Map.has_key?(player.tile_positions, tile_id) do
      player
    else
      {x, y} = next_default_position(player)
      %{player | tile_positions: Map.put(player.tile_positions, tile_id, %{x: x, y: y})}
    end
  end

  defp next_default_position(player) do
    count = map_size(player.tile_positions)
    col = rem(count, 4)
    row = div(count, 4)
    {10.0 + col * 22.0, 10.0 + row * 20.0}
  end
end
