defmodule Tabletop.Tournaments.Pairing.Standings do
  @moduledoc """
  Standings computation following the official Flesh and Blood Tournament Rules
  and Policy (Appendix A.4). Players are ordered by these tiebreakers, in order:

    1. Match points (win/bye = 1, draw/loss = 0)
    2. Cumulative Match Points (CMP) — higher is better
    3. Match Loss % (MLP) — lower is better
    4. Opponents' average Match Loss % (OMLP) — lower is better
    5. Opponents' average Cumulative Match Points (OCMP) — higher is better
    6. A deterministic fallback (registration seed) standing in for the
       official "selected at random".

  CMP, MLP, OMLP and OCMP are all fractions in `0.0..1.0` with no minimum floor,
  and there is no game-level (GW%/OGW%) component.
  """

  alias Tabletop.Tournaments.Pairing.{Player, Scoring}

  def compute(players, opts \\ []) do
    scoring = Keyword.get(opts, :scoring, Scoring.default())
    rounds = total_rounds(players)
    by_id = Map.new(players, &{&1.id, &1})

    # Compute each player's own CMP/MLP once; the opponent averages reuse them.
    cmp_by_id = Map.new(players, &{&1.id, cmp(&1, rounds)})
    mlp_by_id = Map.new(players, &{&1.id, mlp(&1)})

    players
    |> Enum.map(fn p ->
      %{
        id: p.id,
        match_points: match_points(p, scoring),
        wins: p.wins,
        draws: p.draws,
        losses: p.losses,
        cmp: Map.fetch!(cmp_by_id, p.id),
        mlp: Map.fetch!(mlp_by_id, p.id),
        omlp: mean_opponent(p, mlp_by_id),
        ocmp: mean_opponent(p, cmp_by_id)
      }
    end)
    |> Enum.sort_by(fn r ->
      {-r.match_points, -r.cmp, r.mlp, r.omlp, -r.ocmp, seed_of(by_id[r.id])}
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> Map.put(row, :rank, rank) end)
  end

  defp seed_of(%Player{seed: s}) when is_integer(s), do: s
  defp seed_of(_), do: 0

  defp match_points(p, scoring) do
    p.wins * scoring.win + p.draws * scoring.draw + p.losses * scoring.loss
  end

  # Total completed rounds across the whole tournament — the denominator basis
  # for CMP. Derived from the highest round any player has a result for.
  defp total_rounds(players) do
    players
    |> Enum.flat_map(fn p -> Enum.map(p.round_results, & &1.round) end)
    |> case do
      [] -> 0
      rounds -> Enum.max(rounds)
    end
  end

  # Cumulative Match Points: the sum, over each completed round, of the player's
  # running match-point total (a win or a bye earns the point), normalised by an
  # all-wins player's total of R*(R+1)/2. All wins → 1.0; no wins → 0.0; for an
  # equal win count, taking losses later yields a higher CMP.
  defp cmp(_p, 0), do: 0.0

  defp cmp(p, rounds) do
    won = won_rounds(p)

    {total, _running} =
      Enum.reduce(1..rounds, {0, 0}, fn r, {total, running} ->
        running = if MapSet.member?(won, r), do: running + 1, else: running
        {total + running, running}
      end)

    total / (rounds * (rounds + 1) / 2)
  end

  defp won_rounds(p) do
    for %{round: r, result: result} <- p.round_results,
        result in [:win, :bye],
        into: MapSet.new(),
        do: r
  end

  # Match Loss %: losses over the rounds actually played. A bye is not a played
  # round, so it is excluded from the denominator; a draw is not a loss.
  defp mlp(p) do
    played = Enum.count(p.round_results, &(&1.result != :bye))

    if played == 0 do
      0.0
    else
      losses = Enum.count(p.round_results, &(&1.result == :loss))
      losses / played
    end
  end

  defp mean_opponent(p, value_by_id) do
    values =
      p.opponents
      |> Enum.map(&Map.get(value_by_id, &1))
      |> Enum.reject(&is_nil/1)

    case values do
      [] -> 0.0
      vs -> Enum.sum(vs) / length(vs)
    end
  end
end
