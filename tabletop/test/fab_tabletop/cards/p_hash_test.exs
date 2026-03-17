defmodule Tabletop.Cards.PHashTest do
  use ExUnit.Case, async: true

  alias Tabletop.Cards.PHash

  @fixture_path "priv/cards/scar-for-a-scar.webp"
  @art_output_path "/tmp/test_scar_art_crop.png"

  describe "compute_from_file/1" do
    test "produces a 16-char hex hash from a webp image" do
      hash = PHash.compute_from_file(@fixture_path)
      assert is_binary(hash)
      assert String.length(hash) == 16
      assert String.match?(hash, ~r/^[0-9a-f]{16}$/)
    end

    test "is deterministic" do
      h1 = PHash.compute_from_file(@fixture_path)
      h2 = PHash.compute_from_file(@fixture_path)
      assert h1 == h2
    end

    test "computes expected hash for scar-for-a-scar" do
      assert PHash.compute_from_file(@fixture_path) == "26f6a30c93615b9c"
    end

    test "returns nil for invalid file" do
      assert PHash.compute_from_file("priv/cards/nonexistent.webp") == nil
    end
  end

  describe "save_art_region/2" do
    test "extracts art region and writes a PNG" do
      body = File.read!(@fixture_path)
      assert :ok = PHash.save_art_region(body, @art_output_path)
      assert File.exists?(@art_output_path)

      # Verify it's a valid PNG (starts with PNG magic bytes)
      <<0x89, "PNG", _rest::binary>> = File.read!(@art_output_path)

      IO.puts("\n\n  Art crop saved to: #{@art_output_path}")
      IO.puts("  Open it to verify the crop region visually.\n")
    end
  end

  describe "hamming_distance/2" do
    test "identical hashes have distance 0" do
      hash = PHash.compute_from_file(@fixture_path)
      assert PHash.hamming_distance(hash, hash) == 0
    end

    test "completely different hashes have high distance" do
      assert PHash.hamming_distance("0000000000000000", "ffffffffffffffff") == 64
    end

    test "returns 64 for mismatched lengths" do
      assert PHash.hamming_distance("abc", "def") == 64
    end
  end
end
