defmodule Tabletop.Tournaments.Pairing.StandingsTest do
  use ExUnit.Case, async: true

  alias Tabletop.Tournaments.Pairing.{Player, Standings}

  defp p(id, opts), do: struct!(Player, [{:id, id} | opts])

  # A list of round results, numbered from round 1, e.g. rr([:win, :loss, :bye]).
  defp rr(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, round} -> %{round: round, result: result} end)
  end

  test "ranks by match points descending at the official 1/0/0 scale" do
    players = [
      p(1, wins: 3, round_results: rr([:win, :win, :win]), seed: 1, opponents: [2, 3, 4]),
      p(2,
        wins: 2,
        losses: 1,
        round_results: rr([:win, :win, :loss]),
        seed: 2,
        opponents: [1, 3, 4]
      ),
      p(3,
        wins: 1,
        losses: 2,
        round_results: rr([:win, :loss, :loss]),
        seed: 3,
        opponents: [1, 2, 4]
      ),
      p(4, losses: 3, round_results: rr([:loss, :loss, :loss]), seed: 4, opponents: [1, 2, 3])
    ]

    [first, second, third, fourth] = Standings.compute(players)

    assert first.id == 1
    assert first.match_points == 3
    assert first.rank == 1
    assert [second.id, third.id, fourth.id] == [2, 3, 4]
  end

  test "CMP breaks a match-point tie: taking the loss later ranks higher" do
    # Both 2-1, same match points. Player A loses in the final round, B in the first.
    players = [
      p(:b, wins: 2, losses: 1, round_results: rr([:loss, :win, :win]), opponents: [], seed: 2),
      p(:a, wins: 2, losses: 1, round_results: rr([:win, :win, :loss]), opponents: [], seed: 1)
    ]

    [first, second] = Standings.compute(players)

    assert first.id == :a
    assert second.id == :b
    # CMP = sum of cumulative match points after each round / (R*(R+1)/2), R=3.
    assert_in_delta first.cmp, 5 / 6, 0.0001
    assert_in_delta second.cmp, 3 / 6, 0.0001
  end

  test "a bye counts as a win for CMP but is excluded from MLP" do
    # bye, win, loss → 2 match points (bye + win), one played loss out of two played rounds.
    [row] =
      Standings.compute([
        p(:x, wins: 2, losses: 1, round_results: rr([:bye, :win, :loss]), opponents: [])
      ])

    assert row.match_points == 2
    # CMP cumulative: 1, 2, 2 over R=3 → 5/6.
    assert_in_delta row.cmp, 5 / 6, 0.0001
    # MLP: bye round excluded, so 1 loss / 2 played rounds.
    assert_in_delta row.mlp, 0.5, 0.0001
  end

  test "MLP (lower is better) breaks ties when match points and CMP are equal" do
    # Both 2 match points with identical CMP (1,2,2), but pY's middle win was a bye,
    # so pY played fewer rounds and carries a higher loss rate.
    players = [
      p(:y, wins: 2, losses: 1, round_results: rr([:win, :bye, :loss]), opponents: [], seed: 1),
      p(:x, wins: 2, losses: 1, round_results: rr([:win, :win, :loss]), opponents: [], seed: 2)
    ]

    [first, second] = Standings.compute(players)

    assert_in_delta first.cmp, 5 / 6, 0.0001
    assert_in_delta second.cmp, 5 / 6, 0.0001
    assert first.id == :x
    assert_in_delta first.mlp, 1 / 3, 0.0001
    assert second.id == :y
    assert_in_delta second.mlp, 0.5, 0.0001
  end

  test "OMLP and OCMP average the opponents' MLP and CMP, with no floor" do
    players = [
      # Opponent with a perfect record: MLP 0.0, CMP 1.0.
      p(2, wins: 2, round_results: rr([:win, :win]), opponents: [1, 3], seed: 2),
      # Opponent with no wins: MLP 1.0, CMP 0.0.
      p(3, losses: 2, round_results: rr([:loss, :loss]), opponents: [1, 2], seed: 3),
      # Faced both of the above.
      p(1, wins: 1, losses: 1, round_results: rr([:win, :loss]), opponents: [2, 3], seed: 1)
    ]

    rows = Standings.compute(players)
    row1 = Enum.find(rows, &(&1.id == 1))

    assert_in_delta row1.omlp, 0.5, 0.0001
    assert_in_delta row1.ocmp, 0.5, 0.0001
    # No 0.33 floor: a flawless and a winless opponent sit at the true extremes.
    p2 = Enum.find(rows, &(&1.id == 2))
    p3 = Enum.find(rows, &(&1.id == 3))
    assert_in_delta p2.mlp, 0.0, 0.0001
    assert_in_delta p3.mlp, 1.0, 0.0001
  end

  test "ties fall back to the deterministic seed (lower seed first)" do
    players = [
      p(20, wins: 1, round_results: rr([:win]), opponents: [], seed: 2),
      p(10, wins: 1, round_results: rr([:win]), opponents: [], seed: 1)
    ]

    [first, second] = Standings.compute(players)

    assert first.id == 10
    assert second.id == 20
  end
end
