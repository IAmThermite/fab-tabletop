defmodule Tabletop.Fab.Heros do
  @classic_constructed_heros [

  ]

  @silver_age_heros [

  ]

  @living_legend_heros [

  ]

  def heros_for_format(:classic_constructed), do: @classic_constructed_heros
  def heros_for_format(:silver_age), do: @silver_age_heros
  def heros_for_format(:living_legend), do: @living_legend_heros
end
