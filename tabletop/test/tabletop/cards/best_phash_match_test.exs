defmodule Tabletop.Cards.BestPHashMatchTest do
  @moduledoc """
  `Cards.best_phash_match/2` mirrors the ranking inside the SQL of
  `find_by_p_hash_similarity/1`. It feeds the scan-quality metric, so if the two
  drift the metric silently reports a distance for an arm the query never
  actually matched on.
  """
  use ExUnit.Case, async: true

  import Bitwise, only: [<<<: 2, bxor: 2]

  alias Tabletop.Cards
  alias Tabletop.Cards.CardPrint

  # Thresholds mirrored from Tabletop.Cards: art < 15, full < 8.
  @art_threshold 15
  @full_threshold 8

  # Flips `n` low bits of `hash`, producing a hash at Hamming distance exactly `n`.
  defp at_distance(hash, 0), do: hash
  defp at_distance(hash, n), do: bxor(hash, (1 <<< n) - 1)

  @stored_art 0x0123456789ABCDEF
  @stored_full 0x76543210FEDCBA98

  defp print(attrs \\ %{}) do
    struct(
      %CardPrint{image_phash: @stored_art, image_phash_full: @stored_full},
      attrs
    )
  end

  describe "arm selection" do
    test "returns the art arm when only the art hash qualifies" do
      phashes = %{art: at_distance(@stored_art, 3)}

      assert {:art, 3} = Cards.best_phash_match(phashes, print())
    end

    test "returns the full arm when only the whole-card hash qualifies" do
      phashes = %{full: at_distance(@stored_full, 4)}

      assert {:full, 4} = Cards.best_phash_match(phashes, print())
    end

    test "returns art_flipped when the flipped capture is the closer one" do
      phashes = %{
        art: at_distance(@stored_art, 12),
        art_flipped: at_distance(@stored_art, 2)
      }

      assert {:art_flipped, 2} = Cards.best_phash_match(phashes, print())
    end

    test "picks the lowest distance across all qualifying arms" do
      phashes = %{
        art: at_distance(@stored_art, 9),
        art_flipped: at_distance(@stored_art, 14),
        full: at_distance(@stored_full, 2)
      }

      assert {:full, 2} = Cards.best_phash_match(phashes, print())
    end
  end

  describe "threshold enforcement" do
    test "rejects an art distance at the threshold" do
      phashes = %{art: at_distance(@stored_art, @art_threshold)}

      assert Cards.best_phash_match(phashes, print()) == nil
    end

    test "accepts an art distance just under the threshold" do
      phashes = %{art: at_distance(@stored_art, @art_threshold - 1)}

      assert {:art, distance} = Cards.best_phash_match(phashes, print())
      assert distance == @art_threshold - 1
    end

    test "holds the full arm to its own stricter threshold" do
      # A distance that would pass as art but must not pass as full.
      between = @full_threshold + 2
      assert between < @art_threshold

      assert Cards.best_phash_match(%{full: at_distance(@stored_full, between)}, print()) == nil

      assert {:art, ^between} =
               Cards.best_phash_match(%{art: at_distance(@stored_art, between)}, print())
    end
  end

  describe "missing data" do
    test "returns nil when no hashes were captured" do
      assert Cards.best_phash_match(%{}, print()) == nil
    end

    test "ignores arms whose stored hash is nil" do
      # Horizontal prints have no art hash — the full arm must still resolve.
      horizontal = print(%{image_phash: nil})
      phashes = %{art: 123, full: at_distance(@stored_full, 1)}

      assert {:full, 1} = Cards.best_phash_match(phashes, horizontal)
    end

    test "returns nil when the captured hash is nil rather than treating it as distance 64" do
      assert Cards.best_phash_match(%{art: nil, full: nil}, print()) == nil
    end

    test "returns nil for a non-CardPrint" do
      assert Cards.best_phash_match(%{art: @stored_art}, nil) == nil
    end
  end
end
