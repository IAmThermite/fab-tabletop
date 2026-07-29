defmodule Tabletop.Tournaments.Pairing.Swiss do
  @moduledoc """
  Swiss pairing for a single round.

  Groups active players into score brackets, pairs top-half vs bottom-half
  within a bracket, and uses DFS backtracking to avoid rematches. If a bracket
  has an odd number of players, the lowest-ranked one floats down into the
  next bracket. If the total active count is odd, the lowest-ranked player
  who has not yet had a bye receives one.
  """

  alias Tabletop.Tournaments.Pairing.{Player, Scoring}

  def pair(players, round, opts \\ []) when is_list(players) and is_integer(round) do
    scoring = Keyword.get(opts, :scoring, Scoring.default())
    rng_seed = Keyword.get(opts, :rng_seed, {round, length(players)})

    active = Enum.reject(players, & &1.dropped)

    {active, bye_id} = assign_bye(active, scoring)

    sorted = sort_for_pairing(active, scoring, rng_seed)

    case pair_bracketed(sorted, scoring) do
      {:ok, pairings} -> {:ok, %{pairings: pairings, bye: bye_id}}
      :error -> {:error, :no_valid_pairing}
    end
  end

  defp assign_bye(players, _scoring) when rem(length(players), 2) == 0, do: {players, nil}

  defp assign_bye(players, scoring) do
    candidate =
      players
      |> Enum.reject(& &1.had_bye)
      |> Enum.min_by(&bye_priority(&1, scoring), fn -> nil end)

    candidate = candidate || Enum.min_by(players, &bye_priority(&1, scoring))

    {players -- [candidate], candidate.id}
  end

  defp bye_priority(p, scoring), do: {match_points(p, scoring), p.seed || 0}

  defp sort_for_pairing(players, scoring, rng_seed) do
    # Shuffle first so ties break randomly but deterministically per seed.
    seed_state(rng_seed)

    players
    |> Enum.shuffle()
    |> Enum.sort_by(&sort_key(&1, scoring), :desc)
  end

  defp sort_key(p, scoring), do: {match_points(p, scoring), -(p.seed || 0)}

  defp seed_state(seed) when is_integer(seed), do: :rand.seed(:exsss, {seed, seed, seed})

  defp seed_state({a, b}) when is_integer(a) and is_integer(b),
    do: :rand.seed(:exsss, {a, b, a + b})

  defp seed_state(_), do: :rand.seed(:exsss, {1, 2, 3})

  # Group by match points → list of buckets (highest first). Each bucket
  # paired top-half vs bottom-half with backtracking; odd bucket floats its
  # lowest-ranked member into the next bucket.
  defp pair_bracketed(players, scoring) do
    buckets =
      players
      |> Enum.group_by(&match_points(&1, scoring))
      |> Enum.sort_by(fn {pts, _} -> pts end, :desc)
      |> Enum.map(fn {_pts, ps} -> ps end)

    reduce_buckets(buckets, [], [])
  end

  defp reduce_buckets([], [], acc), do: {:ok, Enum.reverse(acc)}

  defp reduce_buckets([], leftovers, acc) do
    # Final float-downs must still pair.
    case pair_bucket(leftovers) do
      {:ok, pairs} -> {:ok, Enum.reverse(acc) ++ pairs}
      :error -> :error
    end
  end

  defp reduce_buckets([bucket | rest], leftovers, acc) do
    combined = leftovers ++ bucket

    {to_pair, float_down} =
      if rem(length(combined), 2) == 1 and rest != [] do
        # Float the lowest-ranked of the combined bucket down.
        [floated | others] = Enum.reverse(combined)
        {Enum.reverse(others), [floated]}
      else
        {combined, []}
      end

    case pair_bucket(to_pair) do
      {:ok, pairs} -> reduce_buckets(rest, float_down, Enum.reverse(pairs) ++ acc)
      :error -> :error
    end
  end

  # Pair within a bucket: DFS with rematch avoidance. For each player, try
  # opponents in preferred order (top-half vs bottom-half match first).
  defp pair_bucket([]), do: {:ok, []}

  defp pair_bucket(players) do
    dfs(players, [])
  end

  defp dfs([], acc), do: {:ok, Enum.reverse(acc)}

  defp dfs([p | rest], acc) do
    ordered = order_candidates(p, rest)

    Enum.reduce_while(ordered, :error, fn opp, _ ->
      case dfs(List.delete(rest, opp), [{p.id, opp.id} | acc]) do
        {:ok, pairs} -> {:halt, {:ok, pairs}}
        :error -> {:cont, :error}
      end
    end)
  end

  # Prefer opponents the player has not yet faced; among those, prefer the
  # standard top-half vs bottom-half partner (index = n/2).
  defp order_candidates(p, rest) do
    n = length(rest)
    preferred_idx = div(n, 2)

    {seen, unseen} = Enum.split_with(rest, fn q -> q.id in p.opponents end)

    ordered_unseen =
      unseen
      |> Enum.with_index()
      |> Enum.sort_by(fn {q, _i} ->
        idx = Enum.find_index(rest, &(&1.id == q.id))
        {abs(idx - preferred_idx), idx}
      end)
      |> Enum.map(fn {q, _} -> q end)

    ordered_unseen ++ seen
  end

  defp match_points(%Player{} = p, scoring) do
    p.wins * scoring.win + p.draws * scoring.draw + p.losses * scoring.loss
  end
end
