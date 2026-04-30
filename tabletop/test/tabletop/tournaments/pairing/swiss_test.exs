defmodule Tabletop.Tournaments.Pairing.SwissTest do
  use ExUnit.Case, async: true

  alias Tabletop.Tournaments.Pairing.{Player, Swiss}

  defp player(id, opts \\ []) do
    struct!(Player, [{:id, id} | opts])
  end

  test "pairs an even field of round-1 players" do
    players = for i <- 1..8, do: player(i, seed: i)
    {:ok, %{pairings: pairings, bye: bye}} = Swiss.pair(players, 1)

    assert bye == nil
    assert length(pairings) == 4

    ids_paired = pairings |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.sort()
    assert ids_paired == Enum.to_list(1..8)
  end

  test "odd field assigns bye to a player without one" do
    players = for i <- 1..9, do: player(i, seed: i)
    {:ok, %{pairings: pairings, bye: bye}} = Swiss.pair(players, 1)

    assert bye in 1..9
    assert length(pairings) == 4
    ids = [bye | pairings |> Enum.flat_map(fn {a, b} -> [a, b] end)] |> Enum.sort()
    assert ids == Enum.to_list(1..9)
  end

  test "does not give a bye to someone who already had one" do
    players =
      [player(1, seed: 1, had_bye: true, losses: 2)] ++
        for(i <- 2..5, do: player(i, seed: i))

    {:ok, %{bye: bye}} = Swiss.pair(players, 2)
    assert bye != 1
  end

  test "avoids rematches when possible" do
    players = [
      player(1, seed: 1, wins: 1, opponents: [2]),
      player(2, seed: 2, losses: 1, opponents: [1]),
      player(3, seed: 3, wins: 1, opponents: [4]),
      player(4, seed: 4, losses: 1, opponents: [3])
    ]

    {:ok, %{pairings: pairings}} = Swiss.pair(players, 2)

    rematches =
      Enum.filter(pairings, fn {a, b} ->
        (a == 1 and b == 2) or (a == 2 and b == 1) or
          (a == 3 and b == 4) or (a == 4 and b == 3)
      end)

    assert rematches == []
  end

  test "excludes dropped players from pairing" do
    players = [
      player(1, seed: 1),
      player(2, seed: 2),
      player(3, seed: 3, dropped: true),
      player(4, seed: 4)
    ]

    {:ok, %{pairings: pairings, bye: bye}} = Swiss.pair(players, 1)
    ids = [bye | pairings |> Enum.flat_map(fn {a, b} -> [a, b] end)] |> Enum.reject(&is_nil/1)
    refute 3 in ids
  end

  test "deterministic given the same rng_seed" do
    players = for i <- 1..8, do: player(i, seed: i)
    {:ok, a} = Swiss.pair(players, 1, rng_seed: 42)
    {:ok, b} = Swiss.pair(players, 1, rng_seed: 42)
    assert a == b
  end
end
