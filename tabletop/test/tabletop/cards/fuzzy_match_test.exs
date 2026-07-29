defmodule Tabletop.Cards.FuzzyMatchTest do
  use Tabletop.DataCase

  import Bitwise, only: [bxor: 2]

  alias Tabletop.Cards
  alias Tabletop.Cards.{Card, CardPrint}

  # Helper: insert a Card + canonical CardPrint pair.
  defp insert_card_with_print(%{name: name} = attrs) do
    {:ok, card} =
      %Card{}
      |> Card.changeset(%{
        name: name,
        pitch: attrs[:pitch],
        external_card_id: attrs[:external_card_id]
      })
      |> Repo.insert()

    print_attrs = %{
      card_id: card.id,
      face_id: attrs[:face_id],
      set_code: attrs[:set_code] || "TST",
      art_type: "regular",
      orientation: attrs[:orientation] || "vertical",
      is_canonical: true,
      image_url: attrs[:image_url] || "https://example.com/#{attrs[:face_id]}.webp",
      image_phash: attrs[:image_phash],
      image_phash_full: attrs[:image_phash_full]
    }

    {:ok, print} =
      %CardPrint{}
      |> CardPrint.changeset(print_attrs)
      |> Repo.insert()

    {card, print}
  end

  # Each entry: {ocr_text, expected_card_name, [seed cards...]}
  @ocr_cases [
    {
      "BEY RALLY THE COAST CASARD",
      "Rally the Coast Guard",
      [
        %{
          name: "Rally the Coast Guard",
          external_card_id: "rally-coast-guard-3",
          pitch: 3,
          face_id: "SEA225",
          set_code: "SEA",
          image_phash: 1_484_317_916_512_072_972
        }
      ]
    },
    {
      # Exact short name should rank above longer cards sharing that prefix
      "Bravo",
      "Bravo",
      [
        %{
          name: "Bravo",
          external_card_id: "bravo-hero",
          face_id: "HER010",
          set_code: "HER",
          image_phash: 1_000_000_000_000_000_001
        },
        %{
          name: "Bravo, Showstopper",
          external_card_id: "bravo-showstopper",
          face_id: "HER011",
          set_code: "HER",
          image_phash: 1_000_000_000_000_000_002
        },
        %{
          name: "Bravo, Flattering Showman",
          external_card_id: "bravo-flattering",
          face_id: "GEM077",
          set_code: "GEM",
          image_phash: 1_000_000_000_000_000_003
        }
      ]
    }
  ]

  # Reference hash (Rally the Coast Guard, pitch 3): 1_484_317_916_512_072_972
  @phash_cases [
    {
      "exact match",
      1_484_317_916_512_072_972,
      "Rally the Coast Guard",
      1_484_317_916_512_072_972
    },
    {
      "3-bit difference (near match)",
      1_484_317_916_512_072_971,
      "Rally the Coast Guard",
      1_484_317_916_512_072_972
    },
    {
      "9-bit difference (at threshold boundary)",
      1_484_317_916_512_072_947,
      "Rally the Coast Guard",
      1_484_317_916_512_072_972
    }
  ]

  describe "find_by_p_hash_similarity/2" do
    for {label, query_hash, expected_name, seed_phash} <- @phash_cases do
      @label label
      @query_hash query_hash
      @expected_name expected_name
      @seed_phash seed_phash

      test "returns correct card for #{label}" do
        insert_card_with_print(%{
          name: @expected_name,
          external_card_id: "ext-#{:erlang.phash2(@label)}",
          face_id: "PHASH_#{:erlang.phash2(@label)}",
          image_phash: @seed_phash
        })

        results = Cards.find_by_p_hash_similarity(%{art: @query_hash})
        names = Enum.map(results, & &1.card.name)

        assert @expected_name in names,
               "Expected #{inspect(@expected_name)} in results, got: #{inspect(names)}"

        assert List.first(names) == @expected_name,
               "Expected #{inspect(@expected_name)} to rank first, got: #{inspect(List.first(names))}"
      end
    end

    test "excludes cards outside the threshold" do
      # 20 bits flipped — beyond the default threshold of 15
      far_hash = 1_484_317_916_512_701_171

      insert_card_with_print(%{
        name: "Some Card",
        external_card_id: "some-card-1",
        face_id: "PHASH_FAR",
        image_phash: 1_484_317_916_512_072_972
      })

      results = Cards.find_by_p_hash_similarity(%{art: far_hash})
      assert results == [], "Expected no results for 20-bit difference, got: #{inspect(results)}"
    end

    test "returns empty list when no cards are close" do
      results = Cards.find_by_p_hash_similarity(%{art: 9_223_372_036_854_775_807})
      assert results == []
    end

    test "ranks closer matches first" do
      base_hash = 0x0F0F0F0F0F0F0F0F

      near_hash = bxor(base_hash, 0b11)
      far_hash = bxor(base_hash, 0b1111_1111)

      insert_card_with_print(%{
        name: "Near Card",
        external_card_id: "near-card",
        face_id: "PHASH_NEAR",
        image_phash: near_hash
      })

      insert_card_with_print(%{
        name: "Far Card",
        external_card_id: "far-card",
        face_id: "PHASH_FAR2",
        image_phash: far_hash
      })

      results = Cards.find_by_p_hash_similarity(%{art: base_hash})
      names = Enum.map(results, & &1.card.name)

      assert List.first(names) == "Near Card",
             "Expected Near Card to rank before Far Card, got: #{inspect(names)}"
    end

    test "horizontal cards match via art/full like vertical cards" do
      # Horizontal cards are rotated to portrait by the scanner and stored the
      # same way as vertical cards (single `image_phash` + `image_phash_full`).
      # There are no left/right halves; the 180° flip is absorbed by sending
      # both `art` and `art_flipped`.
      art_hash = 0x0F0F0F0F0F0F0F0F
      full_hash = 0x33333333_33333333

      insert_card_with_print(%{
        name: "Landscape Card",
        external_card_id: "landscape-1",
        face_id: "LAND001",
        orientation: "horizontal",
        image_phash: art_hash,
        image_phash_full: full_hash
      })

      # Matches via the art arm.
      assert Cards.find_by_p_hash_similarity(%{art: art_hash})
             |> Enum.map(& &1.card.name) == ["Landscape Card"]

      # Player held the card the other way up — the flipped art still resolves
      # it via the art_flipped arm (matched against the same stored image_phash).
      assert Cards.find_by_p_hash_similarity(%{art_flipped: art_hash})
             |> Enum.map(& &1.card.name) == ["Landscape Card"]

      # And the whole-card arm resolves it too.
      assert Cards.find_by_p_hash_similarity(%{full: full_hash})
             |> Enum.map(& &1.card.name) == ["Landscape Card"]
    end
  end

  describe "fuzzy_match_name/1" do
    for {ocr_text, expected_name, seed_cards} <- @ocr_cases do
      @ocr_text ocr_text
      @expected_name expected_name
      @seed_cards seed_cards

      test "resolves #{inspect(ocr_text)} to #{inspect(expected_name)}" do
        for attrs <- @seed_cards do
          insert_card_with_print(attrs)
        end

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
