defmodule Tabletop.Cards.PHashTest do
  use ExUnit.Case, async: true

  alias Tabletop.Cards.PHash

  describe "hamming_distance/2" do
    test "identical hashes have distance 0" do
      assert PHash.hamming_distance(0x0123456789ABCDEF, 0x0123456789ABCDEF) == 0
    end

    test "counts differing bits" do
      assert PHash.hamming_distance(0b1011, 0b0001) == 2
    end

    test "completely different hashes have high distance" do
      assert PHash.hamming_distance(0x0000000000000000, 0xFFFFFFFFFFFFFFFF) == 64
    end

    test "returns 64 for non-integer inputs" do
      assert PHash.hamming_distance("abc", "def") == 64
      assert PHash.hamming_distance(nil, 123) == 64
    end
  end
end
