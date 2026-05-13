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
    effect_counts: %{},
    tile_positions: %{},
    tile_order: []
  }

  def default_player, do: @default_player

  def toggle_damage(player, type) when type in @valid_damage_types do
    new_val = !player[type].active
    new_player = put_in(player, [type, :active], new_val)
    tile_id = Atom.to_string(type)

    new_player =
      if new_val,
        do: ensure_tile_position(new_player, tile_id),
        else: remove_tile(new_player, tile_id)

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
        else: remove_tile(new_player, "goagain")

    {:ok, new_player, {:goagain_toggled, new_val}}
  end

  @valid_effect_categories ["ability", "on_hit"]

  def toggle_effect(player, category, effect_name)
      when category in @valid_effect_categories do
    if valid_effect?(category, effect_name) do
      key = effect_key(category, effect_name)
      new_val = !Map.get(player.effects, key, false)
      new_effects = Map.put(player.effects, key, new_val)
      new_player = %{player | effects: new_effects}

      new_player =
        if new_val,
          do: ensure_tile_position(new_player, key),
          else: remove_tile(new_player, key)

      {:ok, new_player, {:effect_toggled, category, effect_name, new_val}}
    else
      {:error, :invalid_effect}
    end
  end

  def toggle_effect(_, _, _), do: {:error, :invalid_effect}

  def change_effect_count(player, category, effect_name, delta)
      when category in @valid_effect_categories and is_integer(delta) do
    if valid_effect?(category, effect_name) and Effects.counterable?(category, effect_name) do
      key = effect_key(category, effect_name)
      counts = Map.get(player, :effect_counts, %{})
      current = Map.get(counts, key, 1)
      new_count = max(1, current + delta)
      new_counts = Map.put(counts, key, new_count)
      new_player = Map.put(player, :effect_counts, new_counts)

      new_player =
        if Map.get(new_player.effects, key, false) do
          new_player
        else
          new_effects = Map.put(new_player.effects, key, true)
          %{new_player | effects: new_effects} |> ensure_tile_position(key)
        end

      {:ok, new_player, {:effect_count_changed, category, effect_name, new_count}}
    else
      {:error, :invalid_effect}
    end
  end

  def change_effect_count(_, _, _, _), do: {:error, :invalid_effect}

  def effect_key(category, name), do: "#{category}:#{name}"

  def move_tile(player, tile_id, x, y)
      when is_binary(tile_id) and is_number(x) and is_number(y) do
    x = max(0.0, min(100.0, x / 1))
    y = max(0.0, min(100.0, y / 1))
    new_positions = Map.put(player.tile_positions, tile_id, %{x: x, y: y})
    new_order = [tile_id | List.delete(Map.get(player, :tile_order, []), tile_id)]
    new_player = %{player | tile_positions: new_positions, tile_order: new_order}
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

  defp valid_effect?("ability", name) do
    Enum.any?(Effects.abilities(), fn {_key, effect} -> effect[:name] == name end)
  end

  defp valid_effect?("on_hit", name) do
    Enum.any?(Effects.on_hit_effects(), fn {_key, effect} -> effect[:name] == name end)
  end

  defp valid_effect?(_, _), do: false

  defp ensure_tile_position(player, tile_id) do
    if Map.has_key?(player.tile_positions, tile_id) do
      player
    else
      {x, y} = next_default_position(player)
      order = Map.get(player, :tile_order, [])

      %{
        player
        | tile_positions: Map.put(player.tile_positions, tile_id, %{x: x, y: y}),
          tile_order: [tile_id | List.delete(order, tile_id)]
      }
    end
  end

  defp remove_tile(player, tile_id) do
    %{
      player
      | tile_positions: Map.delete(player.tile_positions, tile_id),
        tile_order: List.delete(Map.get(player, :tile_order, []), tile_id)
    }
  end

  # Place each new tile slightly below and to the right of the anchor tile —
  # the most recently placed/moved tile still on the canvas. When the anchor
  # is gone (tile toggled off), we fall through to the next most recent, so
  # new tiles stay clustered with the existing group. If we'd run off the
  # bottom we wrap to the top of the next column.
  @tile_offset_x 0.5
  @tile_offset_y 3.5
  @tile_column_step 5.0
  @max_y 92.0
  @min_y 8.0
  @min_x 5.0
  @max_x 95.0

  defp next_default_position(player) do
    case anchor_position(player) do
      nil ->
        {10.0, 10.0}

      %{x: x, y: y} ->
        new_y = y + @tile_offset_y

        if new_y > @max_y do
          {min(@max_x, x + @tile_column_step), @min_y}
        else
          {min(@max_x, max(@min_x, x + @tile_offset_x)), new_y}
        end
    end
  end

  defp anchor_position(player) do
    player
    |> Map.get(:tile_order, [])
    |> Enum.find_value(fn id -> Map.get(player.tile_positions, id) end)
  end
end
