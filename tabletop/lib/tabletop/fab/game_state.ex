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

  @default_player %{
    life: 40,
    physical: %{active: false, damage: 0},
    arcane: %{active: false, damage: 0},
    amp: %{active: false, value: 0},
    goagain: false,
    effects: %{},
    effect_counts: %{},
    custom_counters: %{},
    proxy_tokens: %{},
    tile_positions: %{},
    tile_order: [],
    mic: true,
    camera: true
  }

  def default_player, do: @default_player

  @doc """
  Applies an action tuple to a player and returns the transform result.

  This is the single mapping from the action vocabulary (the tuples emitted by
  `TabletopWeb.GameControls`) to the per-player transforms in this module. Both
  consumers route through here: `Tabletop.Games.GameSession` (authoritative,
  multiplayer) and the camera-setup preview (local, single-screen). Adding a new
  action means adding its transform plus one clause here — nothing else.

  `move_tile` and the `*_proxy_token` actions carry an owner/target in their
  second element that is irrelevant to the transform (the caller has already
  resolved which player to apply it to), so it is ignored here.
  """
  def transform(player, {:toggle_damage, type}), do: toggle_damage(player, type)
  def transform(player, {:change_damage, type, delta}), do: change_damage(player, type, delta)
  def transform(player, {:toggle_goagain}), do: toggle_goagain(player)
  def transform(player, {:toggle_amp}), do: toggle_amp(player)
  def transform(player, {:change_amp, delta}), do: change_amp(player, delta)
  def transform(player, {:add_custom_counter, name}), do: add_custom_counter(player, name)

  def transform(player, {:change_custom_counter, id, delta}),
    do: change_custom_counter(player, id, delta)

  def transform(player, {:remove_custom_counter, id}), do: remove_custom_counter(player, id)

  def transform(player, {:toggle_effect, category, name}),
    do: toggle_effect(player, category, name)

  def transform(player, {:change_effect_count, category, name, delta}),
    do: change_effect_count(player, category, name, delta)

  def transform(player, {:add_proxy_token, _target, name}), do: add_proxy_token(player, name)

  def transform(player, {:remove_proxy_token, _target, name}),
    do: remove_proxy_token(player, name)

  def transform(player, {:toggle_proxy_token, _target, name}),
    do: toggle_proxy_token(player, name)

  def transform(player, {:change_life, delta}), do: change_life(player, delta)
  def transform(player, {:reset_board}), do: reset_board(player)
  def transform(player, {:set_media, kind, value}), do: set_media(player, kind, value)

  def transform(player, {:move_tile, _target, tile_id, x, y}),
    do: move_tile(player, tile_id, x, y)

  def transform(_player, _action), do: {:error, :unknown_action}

  @valid_media_kinds [:mic, :camera]

  def set_media(player, kind, value) when kind in @valid_media_kinds and is_boolean(value) do
    {:ok, Map.put(player, kind, value), {:media_changed, kind, value}}
  end

  def set_media(_, _, _), do: {:error, :invalid_media}

  def toggle_damage(player, type) when type in @valid_damage_types do
    new_val = !player[type].active
    tile_id = Atom.to_string(type)

    # Turning the tile off resets its damage counter back to 0.
    new_player =
      if new_val do
        player
        |> put_in([type, :active], true)
        |> ensure_tile_position(tile_id)
      else
        player
        |> put_in([type, :active], false)
        |> put_in([type, :damage], 0)
        |> remove_tile(tile_id)
      end

    {:ok, new_player, {:damage_toggled, type, new_val}}
  end

  def toggle_damage(_, _), do: {:error, :invalid_damage_type}

  def change_damage(player, type, delta) when type in @valid_damage_types do
    new_val = max(0, player[type].damage + delta)
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

  @doc """
  Toggles the Amp tile on/off. Amp is a single named tile (like physical/arcane
  damage) carrying a counter — the "X" in Amp X.
  """
  def toggle_amp(player) do
    new_val = !player.amp.active

    # Turning the tile off resets its counter (the "X" in Amp X) back to 0.
    new_player =
      if new_val do
        %{player | amp: %{player.amp | active: true}}
        |> ensure_tile_position("amp")
      else
        %{player | amp: %{player.amp | active: false, value: 0}}
        |> remove_tile("amp")
      end

    {:ok, new_player, {:amp_toggled, new_val}}
  end

  def change_amp(player, delta) when is_integer(delta) do
    new_val = max(0, player.amp.value + delta)
    new_player = %{player | amp: %{player.amp | value: new_val}}
    {:ok, new_player, {:amp_changed, new_val}}
  end

  @custom_counter_name_max 24

  @doc """
  Adds a player-defined counter tile with an optional name. The name is trimmed
  and capped at #{@custom_counter_name_max} characters; a blank name renders as
  just the number on the canvas. Counters are keyed by a generated `"custom:<n>"`
  id so multiple can coexist and never collide with effect keys.
  """
  def add_custom_counter(player, name) when is_binary(name) do
    name =
      name
      |> String.trim()
      |> String.slice(0, @custom_counter_name_max)

    id = "custom:#{System.unique_integer([:positive])}"
    counters = Map.get(player, :custom_counters, %{})
    new_counters = Map.put(counters, id, %{name: name, count: 0})

    new_player =
      %{player | custom_counters: new_counters}
      |> ensure_tile_position(id)

    {:ok, new_player, {:custom_counter_added, id, name}}
  end

  def change_custom_counter(player, id, delta) when is_binary(id) and is_integer(delta) do
    counters = Map.get(player, :custom_counters, %{})

    case Map.get(counters, id) do
      nil ->
        {:error, :unknown_counter}

      counter ->
        # can be negative
        new_count = counter.count + delta
        new_counters = Map.put(counters, id, %{counter | count: new_count})
        new_player = %{player | custom_counters: new_counters}
        {:ok, new_player, {:custom_counter_changed, id, new_count}}
    end
  end

  def remove_custom_counter(player, id) when is_binary(id) do
    counters = Map.get(player, :custom_counters, %{})

    if Map.has_key?(counters, id) do
      new_counters = Map.delete(counters, id)

      new_player =
        %{player | custom_counters: new_counters}
        |> remove_tile(id)

      {:ok, new_player, {:custom_counter_removed, id}}
    else
      {:error, :unknown_counter}
    end
  end

  @valid_effect_categories ["ability", "on_hit", "token"]

  def toggle_effect(player, category, effect_name)
      when category in @valid_effect_categories do
    if valid_effect?(category, effect_name) do
      key = effect_key(category, effect_name)
      new_val = !Map.get(player.effects, key, false)
      new_effects = Map.put(player.effects, key, new_val)
      new_player = %{player | effects: new_effects}

      # Turning the tile off resets its counter (for counterable effects) so a
      # later re-toggle starts fresh at the default rather than the stale count.
      new_player =
        if new_val do
          ensure_tile_position(new_player, key)
        else
          new_counts = Map.delete(Map.get(new_player, :effect_counts, %{}), key)
          %{new_player | effect_counts: new_counts} |> remove_tile(key)
        end

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

  @doc """
  Adds one of `name` to this player's proxy tokens (singletons cap at 1).

  `proxy_tokens` is a `%{name => count}` map of the tokens sitting on *this*
  player — not the tokens they handed out. Either player may add to or clear
  either side's map, so which side a `*_proxy_token` action lands on is decided
  by the caller (`GameSession.resolve_target_side/3`) before it gets here.
  """
  def add_proxy_token(player, name) when is_binary(name) do
    if Effects.valid_token?(name) do
      counts = Map.get(player, :proxy_tokens, %{})

      new_count =
        if Effects.singleton_token?(name),
          do: 1,
          else: Map.get(counts, name, 0) + 1

      new_counts = Map.put(counts, name, new_count)
      new_player = Map.put(player, :proxy_tokens, new_counts)
      {:ok, new_player, {:proxy_token_changed, name, new_count}}
    else
      {:error, :invalid_token}
    end
  end

  def add_proxy_token(_, _), do: {:error, :invalid_token}

  @doc """
  Toggles a singleton proxy token on/off — adds it (count 1) when absent,
  removes it entirely when present. Used by the singleton token checkbox.
  """
  def toggle_proxy_token(player, name) when is_binary(name) do
    if Effects.valid_token?(name) do
      counts = Map.get(player, :proxy_tokens, %{})

      if Map.has_key?(counts, name) do
        new_counts = Map.delete(counts, name)
        new_player = Map.put(player, :proxy_tokens, new_counts)
        {:ok, new_player, {:proxy_token_changed, name, 0}}
      else
        new_counts = Map.put(counts, name, 1)
        new_player = Map.put(player, :proxy_tokens, new_counts)
        {:ok, new_player, {:proxy_token_changed, name, 1}}
      end
    else
      {:error, :invalid_token}
    end
  end

  def toggle_proxy_token(_, _), do: {:error, :invalid_token}

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

  # Tile layout, all in board percentages. `@tile_w`/`@tile_h` are roughly how
  # much of the board a tile covers, and `@slot_step` is the pitch of a stack.
  #
  # A tile is a fixed ~30px tall while a slot is a percentage of the board, so
  # the step has to clear a tile on the *shortest* board people play on — a
  # ~640px-high canvas on a 1280-wide window, where 5% is 32px. Anything tighter
  # (it used to be 3%) stacks fine on a large screen and overlaps on a small one.
  @tile_w 10.0
  @tile_h 4.0
  @slot_step 5.0
  # Vertical distance beyond which two tiles in a column are separate things
  # rather than one stack.
  @max_stack_gap 7.5
  @max_slots 16
  @max_y 92.0
  @min_y 8.0
  @min_x 5.0
  @max_x 95.0

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

    new_positions = maybe_close_vacated_column(new_positions, tile_id, old_pos, %{x: x, y: y})

    new_order = [tile_id | List.delete(Map.get(player, :tile_order, []), tile_id)]
    new_player = %{player | tile_positions: new_positions, tile_order: new_order}
    {:ok, new_player, {:tile_moved, tile_id, x, y}}
  end

  # Dragging a tile clear of its column leaves the same hole in the stack that
  # removing it would, so close it. A move *within* the column is left alone —
  # that is someone arranging the stack by hand, and re-flowing under the drag
  # would fight them. Grouped tiles move as a unit and keep their shape, so
  # there is no hole for them to leave either.
  defp maybe_close_vacated_column(positions, tile_id, %{x: old_x} = old_pos, %{x: new_x}) do
    if is_nil(tile_group(tile_id)) and abs(new_x - old_x) >= @tile_w do
      moved = Map.fetch!(positions, tile_id)

      positions
      |> Map.delete(tile_id)
      |> close_stack_gap(old_pos)
      |> Map.put(tile_id, moved)
    else
      positions
    end
  end

  defp maybe_close_vacated_column(positions, _tile_id, _old_pos, _new_pos), do: positions

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

  def reset_board(player) do
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
    positions = player.tile_positions

    %{
      player
      | tile_positions:
          positions
          |> Map.delete(tile_id)
          |> close_stack_gap(Map.get(positions, tile_id)),
        tile_order: List.delete(Map.get(player, :tile_order, []), tile_id)
    }
  end

  # Taking a tile out of a stack would otherwise leave a hole in the column, so
  # the tiles beneath it slide up to close it: the one directly below takes the
  # removed tile's slot and the rest follow at their existing spacing (a stack
  # someone has hand-adjusted keeps its shape instead of being re-flowed).
  defp close_stack_gap(positions, nil), do: positions

  defp close_stack_gap(positions, %{y: removed_y} = removed) do
    case stack_below(positions, removed) do
      [] ->
        positions

      [{_id, %{y: first_y}} | _] = below ->
        shift = first_y - removed_y

        Enum.reduce(below, positions, fn {id, %{x: x, y: y}}, acc ->
          Map.put(acc, id, %{x: x, y: y - shift})
        end)
    end
  end

  # The contiguous run of tiles stacked under `removed` in the same column,
  # nearest first. A tile parked well below the stack is its own thing and is
  # left where it is, so the run stops at the first larger-than-stack gap.
  defp stack_below(positions, %{x: removed_x, y: removed_y}) do
    positions
    |> Enum.filter(fn {_id, %{x: x, y: y}} -> abs(x - removed_x) < @tile_w and y > removed_y end)
    |> Enum.sort_by(fn {_id, %{y: y}} -> y end)
    |> Enum.reduce_while({[], removed_y}, fn {_id, %{y: y}} = tile, {acc, prev_y} ->
      if y - prev_y <= @max_stack_gap do
        {:cont, {[tile | acc], y}}
      else
        {:halt, {acc, prev_y}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Stack new tiles in a vertical column directly below the anchor (the most
  # recently placed or moved tile still on the canvas). We scan slots downward
  # from the anchor and pick the first one not already occupied, so any gap left
  # in the column — a tile nudged aside, a group dragged off — gets reused
  # before the column extends further.
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
