defmodule Tabletop.Tournaments.Pairing.StandingsTest do
  use ExUnit.Case, async: true

  alias Tabletop.Tournaments.Pairing.{Player, Standings}

  defp p(id, opts), do: struct!(Player, [{:id, id} | opts])

  test "ranks by match points descending" do
    players = [
      p(1, wins: 3, seed: 1, game_wins: 6, game_losses: 2, opponents: [2, 3, 4]),
      p(2, wins: 2, losses: 1, seed: 2, game_wins: 4, game_losses: 3, opponents: [1, 3, 4]),
      p(3, wins: 1, losses: 2, seed: 3, game_wins: 3, game_losses: 4, opponents: [1, 2, 4]),
      p(4, losses: 3, seed: 4, game_wins: 1, game_losses: 6, opponents: [1, 2, 3])
    ]

    [first, second, third, fourth] = Standings.compute(players)
    assert first.id == 1
    assert first.match_points == 9
    assert second.id == 2
    assert third.id == 3
    assert fourth.id == 4
    assert first.rank == 1
  end

  test "floors opponents' match-win % at 0.33" do
    players = [
      p(1, wins: 1, opponents: [2], game_wins: 2),
      p(2, losses: 1, opponents: [1], game_losses: 2)
    ]

    [row1, _row2] = Standings.compute(players)
    assert row1.omw >= 0.33
  end
end
