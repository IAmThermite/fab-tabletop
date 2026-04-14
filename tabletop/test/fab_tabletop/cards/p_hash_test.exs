defmodule Tabletop.Cards.PHashTest do
  use ExUnit.Case, async: true

  alias Tabletop.Cards.PHash

  # Each entry: {fixture_path, expected_hash}
  # Add new test cases here when importing new card sets.
  @hash_cases [
    {"priv/cards/test/scar-for-a-scar-1.webp", 2_806_554_061_580_624_742},
    {"priv/cards/test/scar-for-a-scar-2.webp", 2_806_484_800_938_009_442},
    {"priv/cards/test/scar-for-a-scar-3.webp", 2_806_484_800_938_009_442}
  ]

  @fixture_path "priv/cards/test/scar-for-a-scar-1.webp"
  @art_output_path "/tmp/test_scar_art_crop.png"

  describe "compute_from_file/1" do
    for {path, expected_hash} <- @hash_cases do
      test "computes expected hash for #{Path.basename(path, ".webp")}" do
        assert PHash.compute_from_file(unquote(path)) == unquote(expected_hash)
      end
    end

    test "produces a 64-bit integer hash" do
      hash = PHash.compute_from_file(@fixture_path)
      assert is_integer(hash)
    end

    test "is deterministic" do
      h1 = PHash.compute_from_file(@fixture_path)
      h2 = PHash.compute_from_file(@fixture_path)
      assert h1 == h2
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
      assert PHash.hamming_distance(0x0000000000000000, 0xFFFFFFFFFFFFFFFF) == 64
    end

    test "returns 64 for non-integer inputs" do
      assert PHash.hamming_distance("abc", "def") == 64
    end
  end
end
