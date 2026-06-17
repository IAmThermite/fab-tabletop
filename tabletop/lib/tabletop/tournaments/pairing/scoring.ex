defmodule Tabletop.Tournaments.Pairing.Scoring do
  @moduledoc """
  Point configuration for tournament scoring. Defaults match standard FAB/MTG
  Swiss: 3 points for a match win, 1 for a draw, 0 for a loss, 3 for a bye.
  """

  @default %{win: 3, draw: 1, loss: 0, bye: 3}

  def default, do: @default

  def points_for(result, scoring \\ @default)
  def points_for(:win, s), do: s.win
  def points_for(:loss, s), do: s.loss
  def points_for(:draw, s), do: s.draw
  def points_for(:bye, s), do: s.bye
  def points_for(:double_loss, s), do: s.loss
end
