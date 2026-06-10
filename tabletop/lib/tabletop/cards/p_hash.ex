defmodule Tabletop.Cards.PHash do
  import Bitwise

  @doc """
  Hamming distance between two 64-bit integer pHashes (0-64). Returns 64 for
  any non-integer input.
  """
  def hamming_distance(a, b) when is_integer(a) and is_integer(b) do
    bxor(a, b) |> popcount(0)
  end

  def hamming_distance(_, _), do: 64

  defp popcount(0, acc), do: acc
  defp popcount(n, acc), do: popcount(band(n, n - 1), acc + 1)
end
