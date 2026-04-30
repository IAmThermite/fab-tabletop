defmodule Tabletop.Tournaments.Pairing.BracketTest do
  use ExUnit.Case, async: true

  alias Tabletop.Tournaments.Pairing.Bracket

  test "seeds 4-player bracket as 1v4, 2v3" do
    assert Bracket.seed([:a, :b, :c, :d]) == [{:a, :d}, {:b, :c}]
  end

  test "seeds 8-player bracket with standard crossover" do
    ids = for i <- 1..8, do: i
    # 1v8, 4v5, 2v7, 3v6
    assert Bracket.seed(ids) == [{1, 8}, {4, 5}, {2, 7}, {3, 6}]
  end

  test "raises on non-power-of-two sizes" do
    assert_raise ArgumentError, fn -> Bracket.seed([1, 2, 3]) end
  end

  test "advance pairs winners in order" do
    results = [
      %{pair: {1, 8}, winner: 1},
      %{pair: {4, 5}, winner: 4},
      %{pair: {2, 7}, winner: 2},
      %{pair: {3, 6}, winner: 3}
    ]

    assert {:next, [{1, 4}, {2, 3}]} = Bracket.advance(results)
  end

  test "advance with a single result returns champion" do
    assert {:done, :winner} = Bracket.advance([%{pair: {:winner, :loser}, winner: :winner}])
  end
end
