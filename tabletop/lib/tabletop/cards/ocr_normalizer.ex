defmodule Tabletop.Cards.OcrNormalizer do
  def normalize(text) do
    text
    |> String.upcase()
    |> String.replace(~r/[^A-Z ]/, "")
    |> String.trim()
  end

  def tokens(text) do
    text
    |> normalize()
    |> String.downcase()
    |> String.split(" ", trim: true)
  end
end
