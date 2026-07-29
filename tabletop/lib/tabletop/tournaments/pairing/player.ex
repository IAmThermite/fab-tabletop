defmodule Tabletop.Tournaments.Pairing.Player do
  @moduledoc """
  Plain player struct used by the pairing engine.

  Deliberately free of Ecto and Phoenix — the Tournaments context is
  responsible for translating DB rows into this shape and back.
  """
  @enforce_keys [:id]
  defstruct [
    :id,
    wins: 0,
    losses: 0,
    draws: 0,
    # Per-round match outcomes, one entry per round the player participated in:
    # `%{round: integer, result: :win | :loss | :draw | :bye}`. Backs the
    # cumulative-match-points (CMP) and match-loss-% (MLP) tiebreakers, which
    # depend on *when* results occurred, not just their totals.
    round_results: [],
    opponents: [],
    had_bye: false,
    dropped: false,
    seed: nil
  ]

  def rounds_played(%__MODULE__{wins: w, losses: l, draws: d}), do: w + l + d
end
