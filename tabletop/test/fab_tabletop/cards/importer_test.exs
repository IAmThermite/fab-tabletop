defmodule Tabletop.Cards.ImporterTest do
  use Tabletop.DataCase

  alias Tabletop.Cards
  alias Tabletop.Cards.{Card, CardPrint, Importer}
  alias Tabletop.Repo

  @test_fixture_dir "priv/cards/test"

  defp scar_results(pitch) do
    {:ok, content} = File.read("#{@test_fixture_dir}/scar-for-a-scar-#{pitch}.json")
    {:ok, data} = Jason.decode(content)
    data["results"]
  end

  describe "collect_english_faces/1" do
    test "filters non-English faces and attaches set_code" do
      [first_result | _] = scar_results(1)
      faces = Importer.collect_english_faces(first_result["card_prints"])

      assert Enum.all?(faces, &(&1["face_language"] == "en"))
      assert Enum.all?(faces, &is_binary(&1["set_code"]))
    end

    test "returns [] for missing or non-list input" do
      assert Importer.collect_english_faces(nil) == []
      assert Importer.collect_english_faces(%{}) == []
    end
  end

  describe "foil_dedup/1" do
    test "prefers regular finish over foil within the same (set, art_type, layout) group" do
      faces = [
        %{
          "face_id" => "WTR191",
          "set_code" => "WTR",
          "art_type" => "regular",
          "layout_position" => 10,
          "finish_type" => "regular"
        },
        %{
          "face_id" => "WTR191-RF",
          "set_code" => "WTR",
          "art_type" => "regular",
          "layout_position" => 10,
          "finish_type" => "rainbow-foil"
        }
      ]

      result = Importer.foil_dedup(faces)
      assert length(result) == 1
      assert hd(result)["face_id"] == "WTR191"
    end

    test "keeps one foil face when no regular exists in the group" do
      faces = [
        %{
          "face_id" => "SEA050-MV",
          "set_code" => "SEA",
          "art_type" => "extended-art",
          "layout_position" => 10,
          "finish_type" => "cold-foil"
        },
        %{
          "face_id" => "SEA050-MV-ALT",
          "set_code" => "SEA",
          "art_type" => "extended-art",
          "layout_position" => 10,
          "finish_type" => "cold-foil"
        }
      ]

      result = Importer.foil_dedup(faces)
      assert length(result) == 1
      # Picks the alphabetically-first face_id for stability.
      assert hd(result)["face_id"] == "SEA050-MV"
    end

    test "keeps separate groups across (set, art_type, layout) combinations" do
      faces = [
        %{
          "face_id" => "SEA050",
          "set_code" => "SEA",
          "art_type" => "regular",
          "layout_position" => 10,
          "finish_type" => "regular"
        },
        %{
          "face_id" => "SEA050-MV",
          "set_code" => "SEA",
          "art_type" => "extended-art",
          "layout_position" => 10,
          "finish_type" => "cold-foil"
        },
        %{
          "face_id" => "GEM046-RF",
          "set_code" => "GEM",
          "art_type" => "extended-art",
          "layout_position" => 10,
          "finish_type" => "rainbow-foil"
        }
      ]

      result = Importer.foil_dedup(faces)
      face_ids = result |> Enum.map(& &1["face_id"]) |> Enum.sort()
      assert face_ids == ["GEM046-RF", "SEA050", "SEA050-MV"]
    end

    test "keeps a back face (different layout_position) alongside the front" do
      faces = [
        %{
          "face_id" => "HNT261-MV",
          "set_code" => "HNT",
          "art_type" => "extended-art",
          "layout_position" => 10,
          "finish_type" => "cold-foil"
        },
        %{
          "face_id" => "HNT261-MV_BACK",
          "set_code" => "HNT",
          "art_type" => "full-art",
          "layout_position" => 20,
          "finish_type" => "cold-foil"
        }
      ]

      result = Importer.foil_dedup(faces)
      face_ids = result |> Enum.map(& &1["face_id"]) |> Enum.sort()
      assert face_ids == ["HNT261-MV", "HNT261-MV_BACK"]
    end
  end

  describe "build_card_with_prints/2" do
    setup do
      Req.Test.stub(Tabletop.Cards.ImporterTest, fn conn ->
        body = File.read!("#{@test_fixture_dir}/scar-for-a-scar-1.webp")

        conn
        |> Plug.Conn.put_resp_content_type("image/webp")
        |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, req_options: [plug: {Req.Test, Tabletop.Cards.ImporterTest}]}
    end

    test "returns a card map with embedded prints", %{req_options: req_options} do
      [first | _] = scar_results(1)
      result = Importer.build_card_with_prints(first, req_options)

      assert result.external_card_id == first["id"]
      assert result.name == "Scar for a Scar"
      assert result.pitch == 1
      assert is_list(result.card_prints)
      assert length(result.card_prints) > 0

      Enum.each(result.card_prints, fn print ->
        assert is_binary(print.face_id)
        assert print.orientation == "vertical"
        assert is_integer(print.image_phash)
        assert is_integer(print.image_phash_full)
        assert is_nil(print.image_phash_left)
        assert is_nil(print.image_phash_right)
      end)
    end

    test "marks regular front faces as canonical", %{req_options: req_options} do
      [first | _] = scar_results(1)
      result = Importer.build_card_with_prints(first, req_options)

      regular_prints = Enum.filter(result.card_prints, &(&1.art_type == "regular"))
      assert Enum.all?(regular_prints, & &1.is_canonical)
    end
  end

  describe "import_and_generate/1 (E2E)" do
    setup do
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

      {:ok, output_dir: output_dir, req_options: [plug: {Req.Test, Tabletop.Cards.ImporterTest}]}
    end

    test "writes a JSON snapshot with parent cards + embedded card_prints", %{
      output_dir: output_dir,
      req_options: req_options
    } do
      Importer.import_and_generate(
        raw_path: "#{@test_fixture_dir}/scar-for-a-scar-all.json",
        output_dir: output_dir,
        req_options: req_options,
        insert: false
      )

      generated_files = Path.wildcard("#{output_dir}/cards-*.json")
      assert length(generated_files) == 1

      {:ok, generated_content} = File.read(List.first(generated_files))
      {:ok, generated_cards} = Jason.decode(generated_content)

      scar_cards = Enum.filter(generated_cards, &(&1["name"] == "Scar for a Scar"))
      pitches = scar_cards |> Enum.map(& &1["pitch"]) |> Enum.sort()
      assert 1 in pitches and 2 in pitches and 3 in pitches

      Enum.each(scar_cards, fn card ->
        assert is_binary(card["external_card_id"])
        assert is_list(card["card_prints"])
        assert length(card["card_prints"]) > 0
      end)
    end

    test "inserts Card + CardPrints linked by FK", %{
      output_dir: output_dir,
      req_options: req_options
    } do
      Importer.import_and_generate(
        raw_path: "#{@test_fixture_dir}/scar-for-a-scar-all.json",
        output_dir: output_dir,
        req_options: req_options
      )

      card_prints = Tabletop.Repo.all(CardPrint) |> Repo.preload(:card)
      scar_cards = Enum.filter(card_prints, &(&1.card.name == "Scar for a Scar")) |> Enum.map(& &1.card) |> Enum.uniq()
      assert length(scar_cards) == 3

      pitches = scar_cards |> Enum.map(& &1.pitch) |> Enum.sort()
      assert pitches == [1, 2, 3]

      # Each parent Card should have at least one print across the major sets.
      for card <- scar_cards do
        prints = Repo.all(from cp in CardPrint, where: cp.card_id == ^card.id)
        assert length(prints) > 0
        sets = prints |> Enum.map(& &1.set_code) |> Enum.uniq()
        assert "WTR" in sets or "1HP" in sets
      end
    end
  end

  describe "fetch_raw_card_list/2" do
    setup do
      raw_dir =
        System.tmp_dir!() |> Path.join("raw_fetch_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(raw_dir)
      on_exit(fn -> File.rm_rf!(raw_dir) end)

      # Pre-seed an old file that the fetch should clean up first.
      File.write!(Path.join(raw_dir, "api.cardvault.fabtcg.com-old.json"), "{}")

      Req.Test.stub(Tabletop.Cards.ImporterTest, fn conn ->
        page = conn.params["page"] |> String.to_integer()

        body =
          case page do
            1 ->
              %{
                "count" => 3,
                "next" => "http://example.com/next?page=2",
                "previous" => nil,
                "results" => [%{"card_id" => "a"}, %{"card_id" => "b"}]
              }

            2 ->
              %{
                "count" => 3,
                "next" => nil,
                "previous" => "http://example.com/prev?page=1",
                "results" => [%{"card_id" => "c"}]
              }
          end

        Req.Test.json(conn, body)
      end)

      {:ok, raw_dir: raw_dir, req_options: [plug: {Req.Test, Tabletop.Cards.ImporterTest}]}
    end

    test "writes one file per page and removes existing raw files", %{
      raw_dir: raw_dir,
      req_options: req_options
    } do
      :ok = Importer.fetch_raw_card_list(raw_dir, req_options)

      files =
        Path.wildcard(Path.join(raw_dir, "api.cardvault.fabtcg.com-*.json"))
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      assert files == [
               "api.cardvault.fabtcg.com-1.json",
               "api.cardvault.fabtcg.com-2.json"
             ]

      {:ok, page1_content} =
        File.read(Path.join(raw_dir, "api.cardvault.fabtcg.com-1.json"))

      {:ok, page1} = Jason.decode(page1_content)
      assert length(page1["results"]) == 2
    end
  end

  describe "find_pitch_variants/2" do
    setup do
      # Build three pitch variants of the same logical card, each with a
      # canonical regular print.
      for pitch <- [1, 2, 3] do
        {:ok, card} =
          %Card{}
          |> Card.changeset(%{
            "name" => "Variant Card",
            "pitch" => pitch,
            "external_card_id" => "variant-#{pitch}"
          })
          |> Repo.insert()

        %CardPrint{}
        |> CardPrint.changeset(%{
          "card_id" => card.id,
          "face_id" => "VAR_#{pitch}",
          "set_code" => "TST",
          "art_type" => "regular",
          "orientation" => "vertical",
          "layout_position" => 10,
          "is_canonical" => true,
          "image_url" => "https://example.com/var#{pitch}.webp"
        })
        |> Repo.insert!()
      end

      :ok
    end

    test "returns all pitch variants ordered by pitch ascending" do
      card = Cards.find_by_external_card_id("variant-1")
      variants = Cards.find_pitch_variants(card)

      assert Enum.map(variants, & &1.pitch) == [1, 2, 3]
    end

    test "preloads canonical card_prints" do
      card = Cards.find_by_external_card_id("variant-1")
      [v1 | _] = Cards.find_pitch_variants(card)

      assert is_list(v1.card_prints)
      assert length(v1.card_prints) >= 1
    end

    test "returns empty list for a card without pitch" do
      {:ok, no_pitch} =
        %Card{}
        |> Card.changeset(%{
          "name" => "Hero Card",
          "pitch" => nil,
          "external_card_id" => "hero-1"
        })
        |> Repo.insert()

      assert Cards.find_pitch_variants(no_pitch) == []
    end
  end
end
