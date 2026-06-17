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
    game_wins: 0,
    game_losses: 0,
    game_draws: 0,
    opponents: [],
    had_bye: false,
    dropped: false,
    seed: nil
  ]

  def rounds_played(%__MODULE__{wins: w, losses: l, draws: d}), do: w + l + d
end
