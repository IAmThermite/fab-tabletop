defmodule Tabletop.Tournaments.Pairing.Match do
  @moduledoc """
  Plain match struct used by the pairing engine.

  `result` is one of `:p1_win | :p2_win | :draw | :double_loss | :bye | nil`,
  where `nil` indicates the match has not yet been reported.
  """
  @enforce_keys [:p1_id]
  defstruct [:p1_id, :p2_id, :result, :round, p1_games: 0, p2_games: 0]

  def bye(player_id, round \\ nil) do
    %__MODULE__{p1_id: player_id, p2_id: nil, result: :bye, round: round}
  end
end
