defmodule Tabletop.Cards.ImporterTest do
  use Tabletop.DataCase

  alias Tabletop.Cards
  alias Tabletop.Cards.{Card, Importer}

  @test_fixture_dir "priv/cards/test"

  describe "dedupe_card_prints/1" do
    test "preserves all pitch variants from API response" do
      {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-1.json")
      {:ok, data} = Jason.decode(content)

      faces = Importer.dedupe_card_prints(data["results"])
      pitches = faces |> Enum.map(& &1["printed_pitch"]) |> Enum.sort()

      assert 1 in pitches
      assert 2 in pitches
      assert 3 in pitches
    end

    test "filters non-English faces" do
      {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-1.json")
      {:ok, data} = Jason.decode(content)

      faces = Importer.dedupe_card_prints(data["results"])

      assert Enum.all?(faces, &(&1["face_language"] == "en"))
    end

    test "filters non-regular finish types" do
      {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-1.json")
      {:ok, data} = Jason.decode(content)

      faces = Importer.dedupe_card_prints(data["results"])

      assert Enum.all?(faces, &(&1["finish_type"] == "regular"))
    end

    test "filters non-regular and non-extended-art types" do
      {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-1.json")
      {:ok, data} = Jason.decode(content)

      faces = Importer.dedupe_card_prints(data["results"])

      assert Enum.all?(faces, &(&1["art_type"] in ["regular", "extended-art"]))
    end

    test "dedupes by face_id" do
      {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-1.json")
      {:ok, data} = Jason.decode(content)

      faces = Importer.dedupe_card_prints(data["results"])
      face_ids = Enum.map(faces, & &1["face_id"])

      assert face_ids == Enum.uniq(face_ids)
    end
  end

  describe "import_changeset_from_json/1" do
    setup do
      Req.Test.stub(Tabletop.Cards.ImporterTest, fn conn ->
        body = File.read!("#{@test_fixture_dir}/scar-for-a-scar-1.webp")

        conn
        |> Plug.Conn.put_resp_content_type("image/webp")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, req_options: [plug: {Req.Test, Tabletop.Cards.ImporterTest}]}
    end

    # Helper: get deduped faces from the API fixture (same structure import pipeline uses)
    defp deduped_faces do
      {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-1.json")
      {:ok, data} = Jason.decode(content)
      Importer.dedupe_card_prints(data["results"])
    end

    test "extracts pitch from face JSON", %{req_options: req_options} do
      for face <- deduped_faces() do
        changeset = Importer.import_changeset_from_json(face, req_options)
        assert changeset.changes.pitch == face["printed_pitch"]
      end
    end

    test "handles nil pitch", %{req_options: req_options} do
      face_json = %{
        "printed_name" => "Some Hero",
        "face_id" => "TEST001",
        "printed_pitch" => nil,
        "image" => %{"large" => "https://example.com/test.webp"}
      }

      changeset = Importer.import_changeset_from_json(face_json, req_options)
      assert changeset.changes[:pitch] == nil
    end

    test "extracts name, print_id, and image_url", %{req_options: req_options} do
      face = List.first(deduped_faces())
      changeset = Importer.import_changeset_from_json(face, req_options)

      assert changeset.changes.name == "Scar for a Scar"
      assert changeset.changes.print_id == face["face_id"]
      assert changeset.changes.image_url == get_in(face, ["image", "large"])
    end

    test "generates normalized_name and tokens", %{req_options: req_options} do
      face = List.first(deduped_faces())
      changeset = Importer.import_changeset_from_json(face, req_options)

      assert changeset.changes.normalized_name == "SCAR FOR A SCAR"
      assert changeset.changes.tokens == ["scar", "for", "a", "scar"]
    end
  end

  describe "Card.generated_changeset/2 with pitch" do
    test "accepts pitch value" do
      attrs = %{
        "name" => "Test Card",
        "print_id" => "TEST001",
        "image_url" => "https://example.com/test.webp",
        "normalized_name" => "TEST CARD",
        "tokens" => ["test", "card"],
        "image_phash" => 12345,
        "pitch" => 2
      }

      changeset = Card.generated_changeset(%Card{}, attrs)

      assert changeset.valid?
      assert changeset.changes.pitch == 2
    end

    test "accepts nil pitch" do
      attrs = %{
        "name" => "Test Hero",
        "print_id" => "TEST002",
        "image_url" => "https://example.com/test.webp",
        "normalized_name" => "TEST HERO",
        "tokens" => ["test", "hero"],
        "image_phash" => 67890,
        "pitch" => nil
      }

      changeset = Card.generated_changeset(%Card{}, attrs)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :pitch)
    end
  end

  describe "card_as_json_string/1" do
    test "includes pitch in JSON output" do
      {:ok, card} =
        %Card{}
        |> Card.generated_changeset(%{
          "name" => "Test Card",
          "print_id" => "JSON_TEST_001",
          "image_url" => "https://example.com/test.webp",
          "normalized_name" => "TEST CARD",
          "tokens" => ["test", "card"],
          "image_phash" => 11111,
          "pitch" => 2
        })
        |> Repo.insert()

      json = Cards.card_as_json_string(card)
      decoded = Jason.decode!(json)

      assert decoded["pitch"] == 2
    end

    test "includes nil pitch in JSON output" do
      {:ok, card} =
        %Card{}
        |> Card.generated_changeset(%{
          "name" => "Test Hero",
          "print_id" => "JSON_TEST_002",
          "image_url" => "https://example.com/test.webp",
          "normalized_name" => "TEST HERO",
          "tokens" => ["test", "hero"],
          "image_phash" => 22222
        })
        |> Repo.insert()

      json = Cards.card_as_json_string(card)
      decoded = Jason.decode!(json)

      assert decoded["pitch"] == nil
    end
  end

  describe "find_pitch_variants/1" do
    test "returns all pitch variants for a card" do
      for pitch <- [1, 2, 3] do
        %Card{}
        |> Card.generated_changeset(%{
          "name" => "Variant Card",
          "print_id" => "VAR_#{pitch}",
          "image_url" => "https://example.com/var#{pitch}.webp",
          "normalized_name" => "VARIANT CARD",
          "tokens" => ["variant", "card"],
          "image_phash" => 30000 + pitch,
          "pitch" => pitch
        })
        |> Repo.insert!()
      end

      card = Cards.find_by_print_id("VAR_1")
      variants = Cards.find_pitch_variants(card)

      assert length(variants) == 3
      assert Enum.map(variants, & &1.pitch) == [1, 2, 3]
    end

    test "returns empty list for cards without pitch" do
      card =
        %Card{}
        |> Card.generated_changeset(%{
          "name" => "No Pitch Card",
          "print_id" => "NOPITCH_001",
          "image_url" => "https://example.com/nopitch.webp",
          "normalized_name" => "NO PITCH CARD",
          "tokens" => ["no", "pitch", "card"],
          "image_phash" => 40000
        })
        |> Repo.insert!()

      variants = Cards.find_pitch_variants(card)

      assert variants == []
    end

    test "variants are ordered by pitch ascending" do
      # Insert in reverse order
      for pitch <- [3, 1, 2] do
        %Card{}
        |> Card.generated_changeset(%{
          "name" => "Order Card",
          "print_id" => "ORD_#{pitch}",
          "image_url" => "https://example.com/ord#{pitch}.webp",
          "normalized_name" => "ORDER CARD",
          "tokens" => ["order", "card"],
          "image_phash" => 50000 + pitch,
          "pitch" => pitch
        })
        |> Repo.insert!()
      end

      card = Cards.find_by_print_id("ORD_2")
      variants = Cards.find_pitch_variants(card)

      assert Enum.map(variants, & &1.pitch) == [1, 2, 3]
    end
  end

  describe "import_and_generate/1 (E2E)" do
    test "imports cards with pitch from raw JSON, mocking HTTP" do
      output_dir =
        System.tmp_dir!() |> Path.join("importer_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(output_dir)

      on_exit(fn -> File.rm_rf!(output_dir) end)

      # Use Req.Test to stub HTTP calls
      Req.Test.stub(Tabletop.Cards.ImporterTest, fn conn ->
        cond do
          # API calls for card prints
          String.contains?(conn.request_path, "/card_id/scar-for-a-scar-1/") ->
            json = File.read!("#{@test_fixture_dir}/scar-for-a-scar-1.json")
            Req.Test.json(conn, Jason.decode!(json))

          String.contains?(conn.request_path, "/card_id/scar-for-a-scar-2/") ->
            json = File.read!("#{@test_fixture_dir}/scar-for-a-scar-2.json")
            Req.Test.json(conn, Jason.decode!(json))

          String.contains?(conn.request_path, "/card_id/scar-for-a-scar-3/") ->
            json = File.read!("#{@test_fixture_dir}/scar-for-a-scar-3.json")
            Req.Test.json(conn, Jason.decode!(json))

          # Image downloads — return the webp file bytes
          String.ends_with?(conn.request_path, ".webp") ->
            # Map image URLs to test fixture files by pitch
            fixture =
              cond do
                String.contains?(conn.request_path, "IRA009") or
                    String.contains?(conn.request_path, "WTR191") ->
                  "scar-for-a-scar-1.webp"

                String.contains?(conn.request_path, "UPR210") ->
                  "scar-for-a-scar-2.webp"

                String.contains?(conn.request_path, "UPR211") ->
                  "scar-for-a-scar-3.webp"

                true ->
                  # Default to first image for any other face_id
                  "scar-for-a-scar-1.webp"
              end

            body = File.read!("#{@test_fixture_dir}/#{fixture}")

            conn
            |> Plug.Conn.put_resp_content_type("image/webp")
            |> Plug.Conn.send_resp(200, body)

          true ->
            Plug.Conn.send_resp(conn, 404, "Not found")
        end
      end)

      req_options = [plug: {Req.Test, Tabletop.Cards.ImporterTest}]

      Importer.import_and_generate(
        raw_path: "#{@test_fixture_dir}/scar-for-a-scar-all.json",
        output_dir: output_dir,
        req_options: req_options
      )

      # Verify cards were inserted
      cards = Cards.list_cards()
      scar_cards = Enum.filter(cards, &(&1.name == "Scar for a Scar"))

      assert length(scar_cards) >= 3,
             "Expected at least 3 pitch variants, got #{length(scar_cards)}"

      pitches = scar_cards |> Enum.map(& &1.pitch) |> Enum.sort()
      assert 1 in pitches
      assert 2 in pitches
      assert 3 in pitches

      # All cards should have valid fields
      for card <- scar_cards do
        assert card.name == "Scar for a Scar"
        assert card.normalized_name == "SCAR FOR A SCAR"
        assert card.tokens == ["scar", "for", "a", "scar"]
        assert card.print_id != nil
        assert card.image_url != nil
      end

      # Verify generated JSON was written
      generated_files = Path.wildcard("#{output_dir}/cards-*.json")
      assert length(generated_files) == 1

      {:ok, generated_content} = File.read(List.first(generated_files))
      {:ok, generated_cards} = Jason.decode(generated_content)

      generated_pitches =
        generated_cards
        |> Enum.filter(&(&1["name"] == "Scar for a Scar"))
        |> Enum.map(& &1["pitch"])
        |> Enum.sort()

      assert 1 in generated_pitches
      assert 2 in generated_pitches
      assert 3 in generated_pitches
    end

    test "imports all pitch variants from each set when card exists in multiple sets", %{} do
      output_dir =
        System.tmp_dir!() |> Path.join("importer_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(output_dir)

      on_exit(fn -> File.rm_rf!(output_dir) end)

      Req.Test.stub(Tabletop.Cards.ImporterTest, fn conn ->
        cond do
          String.contains?(conn.request_path, "/card_id/scar-for-a-scar-1/") ->
            json = File.read!("#{@test_fixture_dir}/scar-for-a-scar-1.json")
            Req.Test.json(conn, Jason.decode!(json))

          String.contains?(conn.request_path, "/card_id/scar-for-a-scar-2/") ->
            json = File.read!("#{@test_fixture_dir}/scar-for-a-scar-2.json")
            Req.Test.json(conn, Jason.decode!(json))

          String.contains?(conn.request_path, "/card_id/scar-for-a-scar-3/") ->
            json = File.read!("#{@test_fixture_dir}/scar-for-a-scar-3.json")
            Req.Test.json(conn, Jason.decode!(json))

          String.ends_with?(conn.request_path, ".webp") ->
            body = File.read!("#{@test_fixture_dir}/scar-for-a-scar-1.webp")

            conn
            |> Plug.Conn.put_resp_content_type("image/webp")
            |> Plug.Conn.send_resp(200, body)

          true ->
            Plug.Conn.send_resp(conn, 404, "Not found")
        end
      end)

      req_options = [plug: {Req.Test, Tabletop.Cards.ImporterTest}]

      Importer.import_and_generate(
        raw_path: "#{@test_fixture_dir}/scar-for-a-scar-all.json",
        output_dir: output_dir,
        req_options: req_options
      )

      cards = Cards.list_cards()
      scar_cards = Enum.filter(cards, &(&1.name == "Scar for a Scar"))

      # The fixtures contain prints from multiple sets (e.g. 1HP, WTR, UPR, IRA).
      # The dedup should preserve all pitch variants per set, not collapse across sets.
      for set_code <- ["1HP", "WTR"] do
        set_cards = Enum.filter(scar_cards, &(&1.set_code == set_code))
        set_pitches = Enum.map(set_cards, & &1.pitch) |> Enum.sort()

        assert 1 in set_pitches,
               "Expected pitch 1 for set #{set_code}, got pitches: #{inspect(set_pitches)}"

        assert 2 in set_pitches,
               "Expected pitch 2 for set #{set_code}, got pitches: #{inspect(set_pitches)}"

        assert 3 in set_pitches,
               "Expected pitch 3 for set #{set_code}, got pitches: #{inspect(set_pitches)}"
      end
    end
  end
end
