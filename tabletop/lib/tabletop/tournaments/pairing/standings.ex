defmodule Tabletop.Tournaments.Pairing.Standings do
  @moduledoc """
  Standings computation with FAB-style tiebreakers:

    * Match points
    * Opponents' match-win % (OMW%), floored at 0.33
    * Game-win % (GW%)
    * Opponents' game-win % (OGW%), floored at 0.33

  Byes are excluded from an opponent's denominator when computing OMW/OGW.
  """

  alias Tabletop.Tournaments.Pairing.{Player, Scoring}

  @floor 0.3333

  def compute(players, opts \\ []) do
    scoring = Keyword.get(opts, :scoring, Scoring.default())
    by_id = Map.new(players, &{&1.id, &1})

    players
    |> Enum.map(fn p ->
      mp = match_points(p, scoring)
      mw = match_win_pct(p, scoring)
      gw = game_win_pct(p)

      omw = mean_opponent(p, by_id, &match_win_pct(&1, scoring))
      ogw = mean_opponent(p, by_id, &game_win_pct/1)

      %{id: p.id, match_points: mp, mw: mw, omw: omw, gw: gw, ogw: ogw}
    end)
    |> Enum.sort_by(fn r -> {-r.match_points, -r.omw, -r.gw, -r.ogw, seed_of(by_id[r.id])} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> Map.put(row, :rank, rank) end)
  end

  defp seed_of(%Player{seed: s}) when is_integer(s), do: s
  defp seed_of(_), do: 0

  defp match_points(p, scoring) do
    p.wins * scoring.win + p.draws * scoring.draw + p.losses * scoring.loss
  end

  defp match_win_pct(p, scoring) do
    rounds = p.wins + p.losses + p.draws

    if rounds == 0 do
      @floor
    else
      pts = match_points(p, scoring)
      max(pts / (rounds * scoring.win), @floor)
    end
  end

  defp game_win_pct(p) do
    total = p.game_wins + p.game_losses + p.game_draws

    if total == 0 do
      @floor
    else
      max(p.game_wins / total, @floor)
    end
  end

  defp mean_opponent(p, by_id, fun) do
    opps =
      p.opponents
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.reject(&is_nil/1)

    if opps == [] do
      @floor
    else
      max(Enum.sum(Enum.map(opps, fun)) / length(opps), @floor)
    end
  end
end
