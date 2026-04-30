defmodule Tabletop.Tournaments.Pairing.Bracket do
  @moduledoc """
  Single-elimination bracket seeding and advancement.

  `seed/1` takes an ordered list of player ids (rank 1 first) and returns
  round-1 pairings using standard crossover seeding:

      4 players: [{1, 4}, {2, 3}]
      8 players: [{1, 8}, {4, 5}, {2, 7}, {3, 6}]

  `advance/1` takes a list of round results (pairs + winner id) and returns
  the next round's pairings, or `{:done, champion}` when a single player
  remains.
  """
  def seed(ids) when is_list(ids) do
    size = length(ids)

    unless size in @valid_sizes do
      raise ArgumentError,
            "bracket size must be a power of 2 (got #{size}); pad with byes or trim before calling"
    end

    ids
    |> List.to_tuple()
    |> seed_positions(size)
    |> Enum.map(fn {a, b} -> {elem(List.to_tuple(ids), a - 1), elem(List.to_tuple(ids), b - 1)} end)
  end

  # Produces the standard bracket seed-index pairings for a power-of-two size.
  # Uses the classic recursive construction.
  defp seed_positions(_tuple, size) do
    build_seed_order(size)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] -> {a, b} end)
  end

  defp build_seed_order(1), do: [1]

  defp build_seed_order(n) do
    prev = build_seed_order(div(n, 2))
    Enum.flat_map(prev, fn s -> [s, n + 1 - s] end)
  end

  def advance([%{winner: champion}]), do: {:done, champion}

  def advance(results) when is_list(results) do
    winners = Enum.map(results, & &1.winner)

    pairings =
      winners
      |> Enum.chunk_every(2)
      |> Enum.map(fn [a, b] -> {a, b} end)

    {:next, pairings}
  end
end
