defmodule Tabletop.Cards.FuzzyMatchTest do
  use Tabletop.DataCase

  import Bitwise, only: [bxor: 2]

  alias Tabletop.Cards
  alias Tabletop.Cards.Card

  # Each entry: {ocr_text, expected_card_name, card_attrs_to_seed}
  # Add new test cases here as you encounter OCR failures in the wild.
  # card_attrs must include all required fields for Card.generated_changeset/2.
  @ocr_cases [
    {
      "BEY RALLY THE COAST CASARD",
      "Rally the Coast Guard",
      %{
        "name" => "Rally the Coast Guard",
        "print_id" => "SEA225",
        "image_url" => "https://legendstory-production-s3-public.s3.amazonaws.com/media/cards/large/SEA225.webp",
        "normalized_name" => "RALLY THE COAST GUARD",
        "tokens" => ["rally", "the", "coast", "guard"],
        "image_phash" => 1_484_317_916_512_072_972,
        "pitch" => 3
      }
    },
  ]

  # Reference hash (Rally the Coast Guard, pitch 3): 1_484_317_916_512_072_972
  # Flipping N bits simulates the compression/noise a real pHash from the frontend might have.
  #
  # Each entry: {label, query_hash, expected_card_name, seed_phash}
  # - query_hash: what the frontend sends (may differ slightly from the stored hash)
  # - seed_phash: what is stored in the DB for that card
  #
  # To compute a flipped hash: bxor(base, 0b<N ones>)
  # e.g. 3 bits: bxor(1_484_317_916_512_072_972, 0b111) => 1_484_317_916_512_072_971
  @phash_cases [
    {
      "exact match",
      1_484_317_916_512_072_972,
      "Rally the Coast Guard",
      1_484_317_916_512_072_972
    },
    {
      # 3 bits flipped — well within the default threshold of 10
      "3-bit difference (near match)",
      1_484_317_916_512_072_971,
      "Rally the Coast Guard",
      1_484_317_916_512_072_972
    },
    {
      # 9 bits flipped — still within threshold
      "9-bit difference (at threshold boundary)",
      1_484_317_916_512_072_947,
      "Rally the Coast Guard",
      1_484_317_916_512_072_972
    },
  ]

  describe "find_by_p_hash_similarity/1" do
    for {label, query_hash, expected_name, seed_phash} <- @phash_cases do
      @label label
      @query_hash query_hash
      @expected_name expected_name
      @seed_phash seed_phash

      test "returns correct card for #{label}" do
        %Card{}
        |> Card.generated_changeset(%{
          "name" => @expected_name,
          "print_id" => "PHASH_#{:erlang.phash2(@label)}",
          "image_url" => "https://example.com/test.webp",
          "normalized_name" => String.upcase(@expected_name),
          "tokens" => @expected_name |> String.downcase() |> String.split(" "),
          "image_phash" => @seed_phash
        })
        |> Repo.insert!()

        results = Cards.find_by_p_hash_similarity(@query_hash)
        names = Enum.map(results, & &1.name)

        assert @expected_name in names,
               "Expected #{inspect(@expected_name)} in results, got: #{inspect(names)}"

        assert List.first(names) == @expected_name,
               "Expected #{inspect(@expected_name)} to rank first, got: #{inspect(List.first(names))}"
      end
    end

    test "excludes cards outside the threshold" do
      # 15 bits flipped — beyond the default threshold of 10
      # bxor(1_484_317_916_512_072_972, 0b111_1111_1111_1111) => 1_484_317_916_512_078_579
      far_hash = 1_484_317_916_512_078_579

      %Card{}
      |> Card.generated_changeset(%{
        "name" => "Some Card",
        "print_id" => "PHASH_FAR",
        "image_url" => "https://example.com/far.webp",
        "normalized_name" => "SOME CARD",
        "tokens" => ["some", "card"],
        "image_phash" => 1_484_317_916_512_072_972
      })
      |> Repo.insert!()

      results = Cards.find_by_p_hash_similarity(far_hash)
      assert results == [], "Expected no results for 15-bit difference, got: #{inspect(results)}"
    end

    test "returns empty list when no cards are close" do
      # Use a hash with all high bits set — maximally different from any real card hash
      # (must be within signed int64 range: max is 9_223_372_036_854_775_807)
      results = Cards.find_by_p_hash_similarity(9_223_372_036_854_775_807)
      assert results == []
    end

    test "ranks closer matches first" do
      base_hash = 0x0F0F0F0F0F0F0F0F

      # near: 2 bits flipped, far: 8 bits flipped — both within threshold
      near_hash = bxor(base_hash, 0b11)
      far_hash = bxor(base_hash, 0b1111_1111)

      %Card{}
      |> Card.generated_changeset(%{
        "name" => "Near Card",
        "print_id" => "PHASH_NEAR",
        "image_url" => "https://example.com/near.webp",
        "normalized_name" => "NEAR CARD",
        "tokens" => ["near", "card"],
        "image_phash" => near_hash
      })
      |> Repo.insert!()

      %Card{}
      |> Card.generated_changeset(%{
        "name" => "Far Card",
        "print_id" => "PHASH_FAR2",
        "image_url" => "https://example.com/far2.webp",
        "normalized_name" => "FAR CARD",
        "tokens" => ["far", "card"],
        "image_phash" => far_hash
      })
      |> Repo.insert!()

      results = Cards.find_by_p_hash_similarity(base_hash)
      names = Enum.map(results, & &1.name)

      assert List.first(names) == "Near Card",
             "Expected Near Card to rank before Far Card, got: #{inspect(names)}"
    end
  end

  describe "fuzzy_match_name/1" do
    for {ocr_text, expected_name, seed_attrs} <- @ocr_cases do
      @ocr_text ocr_text
      @expected_name expected_name
      @seed_attrs seed_attrs

      test "resolves #{inspect(ocr_text)} to #{inspect(expected_name)}" do
        %Card{} |> Card.generated_changeset(@seed_attrs) |> Repo.insert!()

        results = Cards.fuzzy_match_name(@ocr_text)
        names = Enum.map(results, & &1.name)

        assert @expected_name in names,
               "Expected #{inspect(@expected_name)} in results, got: #{inspect(names)}"

        assert List.first(names) == @expected_name,
               "Expected #{inspect(@expected_name)} to rank first, got: #{inspect(List.first(names))}"
      end
    end
  end
end
