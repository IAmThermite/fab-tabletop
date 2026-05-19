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
    proxy_tokens: %{},
    tile_positions: %{},
    tile_order: [],
    mic: true,
    camera: true
  }

  def default_player, do: @default_player

  @valid_media_kinds [:mic, :camera]

  def set_media(player, kind, value) when kind in @valid_media_kinds and is_boolean(value) do
    {:ok, Map.put(player, kind, value), {:media_changed, kind, value}}
  end

  def set_media(_, _, _), do: {:error, :invalid_media}

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

  @valid_effect_categories ["ability", "on_hit", "token"]

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

  def add_proxy_token(player, name) when is_binary(name) do
    if Effects.valid_token?(name) do
      counts = Map.get(player, :proxy_tokens, %{})
      new_count = Map.get(counts, name, 0) + 1
      new_counts = Map.put(counts, name, new_count)
      new_player = Map.put(player, :proxy_tokens, new_counts)
      {:ok, new_player, {:proxy_token_changed, name, new_count}}
    else
      {:error, :invalid_token}
    end
  end

  def add_proxy_token(_, _), do: {:error, :invalid_token}

  def remove_proxy_token(player, name) when is_binary(name) do
    if Effects.valid_token?(name) do
      counts = Map.get(player, :proxy_tokens, %{})

      case Map.get(counts, name, 0) do
        n when n <= 1 ->
          new_counts = Map.delete(counts, name)
          new_player = Map.put(player, :proxy_tokens, new_counts)
          {:ok, new_player, {:proxy_token_changed, name, 0}}

        n ->
          new_counts = Map.put(counts, name, n - 1)
          new_player = Map.put(player, :proxy_tokens, new_counts)
          {:ok, new_player, {:proxy_token_changed, name, n - 1}}
      end
    else
      {:error, :invalid_token}
    end
  end

  def remove_proxy_token(_, _), do: {:error, :invalid_token}

  def effect_key(category, name), do: "#{category}:#{name}"

  def move_tile(player, tile_id, x, y)
      when is_binary(tile_id) and is_number(x) and is_number(y) do
    x = max(0.0, min(100.0, x / 1))
    y = max(0.0, min(100.0, y / 1))

    old_pos = Map.get(player.tile_positions, tile_id)
    base_positions = Map.put(player.tile_positions, tile_id, %{x: x, y: y})

    new_positions =
      case {tile_group(tile_id), old_pos} do
        {nil, _} ->
          base_positions

        {_, nil} ->
          base_positions

        {group, %{x: ox, y: oy}} ->
          dx = x - ox
          dy = y - oy

          Enum.reduce(player.tile_positions, base_positions, fn {sib_id, %{x: sx, y: sy}}, acc ->
            if sib_id != tile_id and tile_group(sib_id) == group do
              Map.put(acc, sib_id, %{
                x: max(0.0, min(100.0, sx + dx)),
                y: max(0.0, min(100.0, sy + dy))
              })
            else
              acc
            end
          end)
      end

    new_order = [tile_id | List.delete(Map.get(player, :tile_order, []), tile_id)]
    new_player = %{player | tile_positions: new_positions, tile_order: new_order}
    {:ok, new_player, {:tile_moved, tile_id, x, y}}
  end

  defp tile_group(tile_id) when is_binary(tile_id) do
    cond do
      String.starts_with?(tile_id, "ability:") -> :ability
      String.starts_with?(tile_id, "on_hit:") -> :on_hit
      String.starts_with?(tile_id, "token:") -> :on_hit
      true -> nil
    end
  end

  defp tile_group(_), do: nil

  def change_life(player, delta) do
    new_life = max(0, player.life + delta)
    {:ok, %{player | life: new_life}, {:life_changed, new_life}}
  end

  def reset_chain(player) do
    reset = %{
      @default_player
      | life: player.life,
        tile_positions: %{},
        proxy_tokens: Map.get(player, :proxy_tokens, %{})
    }

    {:ok, reset, :chain_reset}
  end

  defp valid_effect?("ability", name) do
    Enum.any?(Effects.abilities(), fn {_key, effect} -> effect[:name] == name end)
  end

  defp valid_effect?("on_hit", name) do
    Enum.any?(Effects.on_hit_effects(), fn {_key, effect} -> effect[:name] == name end)
  end

  defp valid_effect?("token", name), do: Effects.valid_token?(name)

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

  # Stack new tiles in a vertical column directly below the anchor (the most
  # recently placed or moved tile still on the canvas). We scan slots
  # downward from the anchor and pick the first one not already occupied, so
  # when a tile is removed the gap it leaves gets filled by the next tile
  # added before the column extends further.
  @tile_w 10.0
  @tile_h 2.5
  @slot_step 3.0
  @max_slots 16
  @max_y 92.0
  @min_y 8.0
  @min_x 5.0
  @max_x 95.0

  defp next_default_position(player) do
    case anchor_position(player) do
      nil ->
        {10.0, 10.0}

      anchor ->
        occupied =
          player.tile_positions
          |> Map.values()
          |> Enum.map(fn %{x: x, y: y} -> {x, y} end)

        find_column_position(anchor, occupied, 1)
    end
  end

  defp find_column_position(%{x: cx, y: cy} = anchor, occupied, slot)
       when slot <= @max_slots do
    candidate = {cx, cy + slot * @slot_step}

    if position_open?(candidate, occupied) do
      clamp_position(candidate)
    else
      find_column_position(anchor, occupied, slot + 1)
    end
  end

  defp find_column_position(%{x: cx, y: cy}, _occupied, _slot),
    do: clamp_position({cx, cy + @slot_step})

  defp position_open?({x, y}, occupied) do
    Enum.all?(occupied, fn {ox, oy} ->
      abs(x - ox) >= @tile_w or abs(y - oy) >= @tile_h
    end)
  end

  defp clamp_position({x, y}) do
    {min(@max_x, max(@min_x, x)), min(@max_y, max(@min_y, y))}
  end

  defp anchor_position(player) do
    player
    |> Map.get(:tile_order, [])
    |> Enum.find_value(fn id -> Map.get(player.tile_positions, id) end)
  end
end
