defmodule Tabletop.Tournaments.Pairing.Scoring do
  @moduledoc """
  Point configuration for tournament scoring. Defaults mirror the official
  Flesh and Blood Tournament Rules and Policy (Appendix A.4): a match win and a
  bye are each worth 1 point, while draws and losses are worth 0.
  """

  @default %{win: 1, draw: 0, loss: 0, bye: 1}

  def default, do: @default

  def points_for(result, scoring \\ @default)
  def points_for(:win, s), do: s.win
  def points_for(:loss, s), do: s.loss
  def points_for(:draw, s), do: s.draw
  def points_for(:bye, s), do: s.bye
  def points_for(:double_loss, s), do: s.loss
end
