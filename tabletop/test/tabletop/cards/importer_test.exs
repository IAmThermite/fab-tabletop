defmodule Tabletop.Cards.ImporterTest do
  use Tabletop.DataCase

  alias Tabletop.Cards
  alias Tabletop.Cards.{Card, CardPrint, Importer}

  # Writes the given card list (the flesh-and-blood-cards `card.json` shape) to a
  # temp file and returns its path.
  defp write_source(cards) do
    path =
      Path.join(System.tmp_dir!(), "importer_test_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(cards))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp printing(attrs) do
    Map.merge(
      %{
        "unique_id" => "u-#{System.unique_integer([:positive])}",
        "id" => "AAA001",
        "set_id" => "AAA",
        "foiling" => "S",
        "art_variations" => [],
        "image_url" => "https://example.com/AAA001.png",
        "phash_art" => "111",
        "phash_full" => "222"
      },
      attrs
    )
  end

  defp prints_for(external_card_id) do
    %Card{} = card = Cards.find_by_external_card_id(external_card_id)
    Repo.preload(card, :card_prints).card_prints
  end

  describe "build_card/1" do
    test "maps card + printing fields onto the snapshot shape" do
      card =
        Importer.build_card(%{
          "unique_id" => "ext-1",
          "name" => "Test Card",
          "pitch" => "2",
          "played_horizontally" => false,
          "printings" => [printing(%{"unique_id" => "face-1", "set_id" => "MST"})]
        })

      assert card.external_card_id == "ext-1"
      assert card.name == "Test Card"
      assert card.pitch == 2

      assert [print] = card.card_prints
      # face_id comes from the printing's unique_id, not its `id`.
      assert print.face_id == "face-1"
      assert print.set_code == "MST"
      assert print.orientation == "vertical"
      assert print.image_phash == 111
      assert print.image_phash_full == 222
    end

    test "pitch \"\" becomes nil (not 0)" do
      card =
        Importer.build_card(%{
          "unique_id" => "ext-weapon",
          "name" => "Weapon",
          "pitch" => "",
          "printings" => [printing(%{})]
        })

      assert card.pitch == nil
    end

    test "collapses foiling variants that share an image, preferring standard" do
      card =
        Importer.build_card(%{
          "unique_id" => "ext-foil",
          "name" => "Foiled",
          "printings" => [
            printing(%{"unique_id" => "rainbow", "foiling" => "R", "phash_full" => "999"}),
            printing(%{"unique_id" => "standard", "foiling" => "S", "phash_full" => "999"})
          ]
        })

      assert [print] = card.card_prints
      assert print.face_id == "standard"
    end

    test "keeps a cold-foil print whose image genuinely differs" do
      card =
        Importer.build_card(%{
          "unique_id" => "ext-cold",
          "name" => "Cold",
          "printings" => [
            printing(%{"unique_id" => "std", "foiling" => "S", "phash_full" => "100"}),
            printing(%{"unique_id" => "cold", "foiling" => "C", "phash_full" => "200"})
          ]
        })

      face_ids = Enum.map(card.card_prints, & &1.face_id) |> Enum.sort()
      assert face_ids == ["cold", "std"]
    end

    test "marks exactly one print canonical (regular art, standard foiling)" do
      card =
        Importer.build_card(%{
          "unique_id" => "ext-canon",
          "name" => "Canon",
          "printings" => [
            printing(%{"unique_id" => "fa", "art_variations" => ["FA"], "phash_full" => "1"}),
            printing(%{"unique_id" => "reg", "art_variations" => [], "phash_full" => "2"})
          ]
        })

      canonical = Enum.filter(card.card_prints, & &1.is_canonical)
      assert [%{face_id: "reg", art_type: "regular"}] = canonical

      fa = Enum.find(card.card_prints, &(&1.face_id == "fa"))
      assert fa.art_type == "full_art"
      refute fa.is_canonical
    end

    test "horizontal card has no art hash, full hash only" do
      card =
        Importer.build_card(%{
          "unique_id" => "ext-meld",
          "name" => "A // B",
          "played_horizontally" => true,
          # phash_art absent for horizontal printings
          "printings" => [printing(%{"phash_art" => nil}) |> Map.delete("phash_art")]
        })

      assert [print] = card.card_prints
      assert print.orientation == "horizontal"
      assert print.image_phash == nil
      assert print.image_phash_full == 222
    end

    test "drops imageless printings and skips a fully-imageless card" do
      assert Importer.build_card(%{
               "unique_id" => "ext-noimg",
               "name" => "No Image",
               "printings" => [printing(%{"image_url" => nil})]
             }) == nil
    end
  end

  describe "import_all/1" do
    test "upserts: a re-run propagates upstream corrections without duplicating" do
      card = fn name, phash ->
        [
          %{
            "unique_id" => "ext-up",
            "name" => name,
            "pitch" => "1",
            "printings" => [printing(%{"unique_id" => "up-1", "phash_full" => phash})]
          }
        ]
      end

      assert {1, 0} = Importer.import_all(source: write_source(card.("Old Name", "1")))

      # Upstream fixes the name and the full pHash for the same card/face.
      assert {1, 0} = Importer.import_all(source: write_source(card.("New Name", "42")))

      assert Repo.aggregate(Card, :count) == 1
      assert Repo.aggregate(CardPrint, :count) == 1

      [print] = prints_for("ext-up")
      assert Cards.find_by_external_card_id("ext-up").name == "New Name"
      assert print.image_phash_full == 42
    end

    test "inserts cards + prints and is idempotent on re-run" do
      source =
        write_source([
          %{
            "unique_id" => "ext-a",
            "name" => "Card A",
            "pitch" => "1",
            "printings" => [
              printing(%{"unique_id" => "a-s", "foiling" => "S", "phash_full" => "10"}),
              printing(%{"unique_id" => "a-r", "foiling" => "R", "phash_full" => "10"}),
              printing(%{"unique_id" => "a-fa", "art_variations" => ["FA"], "phash_full" => "11"})
            ]
          },
          %{
            "unique_id" => "ext-skip",
            "name" => "Skipped",
            "printings" => [printing(%{"image_url" => nil})]
          }
        ])

      assert {1, 1} = Importer.import_all(source: source)

      prints = prints_for("ext-a")
      assert length(prints) == 2
      assert Enum.count(prints, & &1.is_canonical) == 1

      # Re-run: no new cards or prints.
      assert {1, 1} = Importer.import_all(source: source)
      assert length(prints_for("ext-a")) == 2
      assert Repo.aggregate(Card, :count) == 1
      assert Repo.aggregate(CardPrint, :count) == 2
    end

    test "imports the real Scar for a Scar card.json fixture" do
      # Real card.json extract: three pitch variants, heavy foil/edition reprinting
      # that collapses on shared phash_full (16/6/6 printings -> 9/3/3 prints).
      assert {3, 0} = Importer.import_all(source: "priv/cards/test/scar-for-a-scar-all.json")

      variants = %{
        "DbpqBt8Gp8HWg6QMFBBgh" => {1, 9},
        "LwdKpBTcMk6rLjDwG8r6G" => {2, 3},
        "fBjC6dqfrGN9TG7Whh9TR" => {3, 3}
      }

      for {ext, {pitch, count}} <- variants do
        card = Cards.find_by_external_card_id(ext)
        assert card.name == "Scar for a Scar"
        assert card.pitch == pitch

        prints = prints_for(ext)
        assert length(prints) == count
        # Exactly one canonical, and it is a regular (non-alternate) printing.
        assert [canonical] = Enum.filter(prints, & &1.is_canonical)
        assert canonical.art_type == "regular"
        # All printings are vertical and imaged, so both hash arms are populated.
        assert Enum.all?(prints, &(&1.image_phash && &1.image_phash_full))
        assert Enum.all?(prints, &(&1.orientation == "vertical"))
      end

      assert Repo.aggregate(CardPrint, :count) == 15
    end
  end

  describe "re-running against a grown source" do
    test "adds new cards, adds new prints to existing cards, and refreshes hashes" do
      first =
        write_source([
          %{
            "unique_id" => "ext-grow",
            "name" => "Grower",
            "printings" => [
              printing(%{"unique_id" => "g-1", "phash_art" => "10", "phash_full" => "11"})
            ]
          }
        ])

      assert {1, 0} = Importer.import_all(source: first)
      assert [%{face_id: "g-1", id: print_id}] = prints_for("ext-grow")
      card_id = Cards.find_by_external_card_id("ext-grow").id

      # Upstream adds a printing to the existing card, corrects its hash, and
      # ships a brand-new card.
      second =
        write_source([
          %{
            "unique_id" => "ext-grow",
            "name" => "Grower",
            "printings" => [
              printing(%{"unique_id" => "g-1", "phash_art" => "10", "phash_full" => "99"}),
              printing(%{"unique_id" => "g-2", "phash_art" => "20", "phash_full" => "21"})
            ]
          },
          %{
            "unique_id" => "ext-new",
            "name" => "Newcomer",
            "printings" => [
              printing(%{"unique_id" => "n-1", "phash_art" => "30", "phash_full" => "31"})
            ]
          }
        ])

      assert {2, 0} = Importer.import_all(source: second)

      # The existing card kept its row, gained the new print, and the print it
      # already had kept its row while picking up the corrected hash.
      assert Cards.find_by_external_card_id("ext-grow").id == card_id
      prints = prints_for("ext-grow")
      assert Enum.map(prints, & &1.face_id) |> Enum.sort() == ["g-1", "g-2"]

      existing = Enum.find(prints, &(&1.face_id == "g-1"))
      assert existing.id == print_id
      assert existing.image_phash_full == 99

      # And the new card arrived.
      assert %Card{} = Cards.find_by_external_card_id("ext-new")
      assert [%{face_id: "n-1"}] = prints_for("ext-new")
    end
  end

  describe "replace_all" do
    # Two printings that share an image collapse to one print. Correcting the
    # second one's hash upstream makes it a distinct print again — and reverting
    # that correction makes the first print stop being produced, which is how a
    # print goes stale without upstream deleting anything.
    defp two_print_card(full_hash_b) do
      [
        %{
          "unique_id" => "ext-stale",
          "name" => "Stale Maker",
          "printings" => [
            printing(%{"unique_id" => "s-a", "phash_art" => "1", "phash_full" => "10"}),
            printing(%{
              "unique_id" => "s-b",
              "foiling" => "R",
              "phash_art" => "2",
              "phash_full" => full_hash_b
            })
          ]
        }
      ]
    end

    setup do
      # First run: distinct hashes, so both printings survive as prints.
      assert {1, 0} = Importer.import_all(source: write_source(two_print_card("20")))
      assert length(prints_for("ext-stale")) == 2

      # Second run: the two now share an image, so "s-b" collapses into "s-a"
      # and is no longer produced by the source.
      %{source: write_source(two_print_card("10"))}
    end

    test "clears the pHashes of prints the source no longer produces", %{source: source} do
      assert {1, 0} = Importer.import_all(source: source, replace_all: true)

      prints = Map.new(prints_for("ext-stale"), &{&1.face_id, &1})

      # Still produced -> keeps its hashes.
      assert prints["s-a"].image_phash == 1
      assert prints["s-a"].image_phash_full == 10

      # No longer produced -> hashes cleared, so the scanner cannot match it.
      assert is_nil(prints["s-b"].image_phash)
      assert is_nil(prints["s-b"].image_phash_full)
    end

    test "keeps the row rather than deleting it", %{source: source} do
      assert {1, 0} = Importer.import_all(source: source, replace_all: true)

      assert length(prints_for("ext-stale")) == 2
      assert Repo.aggregate(CardPrint, :count) == 2
    end

    test "is off by default — a stale print keeps its hashes", %{source: source} do
      assert {1, 0} = Importer.import_all(source: source)

      prints = Map.new(prints_for("ext-stale"), &{&1.face_id, &1})
      assert prints["s-b"].image_phash == 2
      assert prints["s-b"].image_phash_full == 20
    end

    test "leaves prints belonging to cards outside the source alone" do
      # A card this run never mentions is not "stale" — it is simply not part of
      # this import, and blanking it would make a partial source destructive.
      other =
        write_source([
          %{
            "unique_id" => "ext-other",
            "name" => "Other",
            "printings" => [
              printing(%{"unique_id" => "o-1", "phash_art" => "7", "phash_full" => "8"})
            ]
          }
        ])

      assert {1, 0} = Importer.import_all(source: other)
      assert {1, 0} = Importer.import_all(source: other, replace_all: true)

      assert [print] = prints_for("ext-other")
      assert print.image_phash == 7
      assert print.image_phash_full == 8
    end
  end

  describe "hash-less source" do
    # Every arm of `Cards.find_by_p_hash_similarity/1` is guarded on the stored
    # hash being non-NULL, and the upsert re-runs the changeset over each print —
    # so importing a source that lost its hashes writes NULL over good ones and
    # the scanner stops matching anything, reporting success the whole way.
    defp hashless_source(ctx) do
      Map.put(
        ctx,
        :source,
        write_source([
          %{
            "unique_id" => "ext-nohash",
            "name" => "No Hashes",
            "printings" => [
              printing(%{"unique_id" => "nohash-1", "phash_art" => nil, "phash_full" => nil})
            ]
          }
        ])
      )
    end

    setup :hashless_source

    test "raises rather than nulling out every hash in the table", %{source: source} do
      assert_raise RuntimeError, ~r/none of 1 card prints carry a pHash/, fn ->
        Importer.import_all(source: source)
      end

      # Nothing was written.
      assert Repo.aggregate(CardPrint, :count) == 0
    end

    test "an existing print keeps its hashes when the import is refused", %{source: source} do
      assert {1, 0} =
               Importer.import_all(
                 source:
                   write_source([
                     %{
                       "unique_id" => "ext-nohash",
                       "name" => "No Hashes",
                       "printings" => [
                         printing(%{
                           "unique_id" => "nohash-1",
                           "phash_art" => "555",
                           "phash_full" => "666"
                         })
                       ]
                     }
                   ])
               )

      assert_raise RuntimeError, fn ->
        Importer.import_all(source: source)
      end

      assert [print] = prints_for("ext-nohash")
      assert print.image_phash == 555
      assert print.image_phash_full == 666
    end

    test "imports anyway when explicitly allowed", %{source: source} do
      assert {1, 0} =
               Importer.import_all(source: source, allow_missing_phashes: true)

      assert [print] = prints_for("ext-nohash")
      assert is_nil(print.image_phash)
      assert is_nil(print.image_phash_full)
    end

    test "hash-less printings are not collapsed into a single print" do
      # `dedup_by_image/1` groups on `image_phash_full`. A nil hash means "image
      # identity unknown", so grouping on it would fold every printing of a card
      # into one — which is how a hash-less import also silently loses prints.
      source =
        write_source([
          %{
            "unique_id" => "ext-many",
            "name" => "Many Printings",
            "printings" => [
              printing(%{"unique_id" => "m-1", "phash_art" => nil, "phash_full" => nil}),
              printing(%{"unique_id" => "m-2", "phash_art" => nil, "phash_full" => nil}),
              printing(%{"unique_id" => "m-3", "phash_art" => nil, "phash_full" => nil})
            ]
          }
        ])

      assert {1, 0} =
               Importer.import_all(source: source, allow_missing_phashes: true)

      assert length(prints_for("ext-many")) == 3
      assert Enum.count(prints_for("ext-many"), & &1.is_canonical) == 1
    end
  end
end
