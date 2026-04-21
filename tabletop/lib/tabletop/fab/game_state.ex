defmodule Tabletop.Fab.GameState do
  @moduledoc """
  Pure per-player state transforms for the FaB tabletop.

  The authoritative session state is owned by `Tabletop.Games.GameSession`, which
  holds two player maps (one per user) and dispatches incoming actions to the
  functions in this module. Each transform takes a player map and returns
  `{:ok, new_player, broadcast_delta}` or `{:error, reason}`.
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

  def default_player, do: @default_player

  def toggle_damage(player, type) when type in @valid_damage_types do
    new_val = !player[type].active
    new_player = put_in(player, [type, :active], new_val)
    tile_id = Atom.to_string(type)

    new_player =
      if new_val,
        do: ensure_tile_position(new_player, tile_id),
        else: %{new_player | tile_positions: Map.delete(new_player.tile_positions, tile_id)}

    {:ok, new_player, {:damage_toggled, type, new_val}}
  end

  def toggle_damage(_, _), do: {:error, :invalid_damage_type}

  def change_damage(player, type, delta) when type in @valid_damage_types do
    new_val = max(@min_damage, player[type].damage + delta)
    new_player = put_in(player, [type, :damage], new_val)
    {:ok, new_player, {:damage_changed, type, new_val}}
  end

  def change_damage(_, _, _), do: {:error, :invalid_damage_type}

  def toggle_goagain(player) do
    new_val = !player.goagain
    new_player = %{player | goagain: new_val}

    new_player =
      if new_val,
        do: ensure_tile_position(new_player, "goagain"),
        else: %{new_player | tile_positions: Map.delete(new_player.tile_positions, "goagain")}

    {:ok, new_player, {:goagain_toggled, new_val}}
  end

  def toggle_effect(player, effect_name) do
    if valid_effect?(effect_name) do
      new_val = !Map.get(player.effects, effect_name, false)
      new_effects = Map.put(player.effects, effect_name, new_val)
      new_player = %{player | effects: new_effects}

      new_player =
        if new_val,
          do: ensure_tile_position(new_player, effect_name),
          else: %{new_player | tile_positions: Map.delete(new_player.tile_positions, effect_name)}

      {:ok, new_player, {:effect_toggled, effect_name, new_val}}
    else
      {:error, :invalid_effect}
    end
  end

  def move_tile(player, tile_id, x, y)
      when is_binary(tile_id) and is_number(x) and is_number(y) do
    x = max(0.0, min(100.0, x / 1))
    y = max(0.0, min(100.0, y / 1))
    new_positions = Map.put(player.tile_positions, tile_id, %{x: x, y: y})
    new_player = %{player | tile_positions: new_positions}
    {:ok, new_player, {:tile_moved, tile_id, x, y}}
  end

  def change_life(player, delta) do
    new_life = player.life + delta
    {:ok, %{player | life: new_life}, {:life_changed, new_life}}
  end

  def reset_chain(player) do
    reset = %{@default_player | life: player.life, tile_positions: %{}}
    {:ok, reset, :chain_reset}
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
