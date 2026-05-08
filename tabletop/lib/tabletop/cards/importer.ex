defmodule Tabletop.Cards.Importer do
  @moduledoc """
  Imports card data from cardvault into the database.

  Two-step pipeline:
    1. `import_and_generate/1` — fetch each card_id from the API, compute
       hashes and bboxes, write a JSON snapshot under `priv/cards/generated/`.
    2. `import_from_generated_data/0` — read those snapshots and insert into
       the database. Idempotent on `(external_card_id, face_id)`.

  Output JSON shape (one entry per logical card; embedded `card_prints`):

      [
        {
          "external_card_id": "...",
          "name": "...",
          "pitch": 1,
          "card_prints": [
            {
              "face_id": "...",
              "set_code": "...",
              "art_type": "regular",
              "orientation": "vertical",
              "layout_position": 10,
              "is_canonical": true,
              "image_url": "...",
              "art_bbox": {"x": 0.1, "y": 0.16, "w": 0.8, "h": 0.42},
              "image_phash": 1234,
              "image_phash_left": null,
              "image_phash_right": null,
              "image_phash_full": 5678
            }
          ]
        }
      ]
  """

  require Logger

  alias Tabletop.Cards
  alias Tabletop.Cards.{ArtBboxDetector, Card, CardPrint, PHash}

  @fetch_concurrency 10
  @phash_concurrency 15
  @task_timeout :timer.seconds(60)

  @raw_page_size 1000
  @raw_search_url "https://api.cardvault.fabtcg.com/carddb/api/v1/advanced-search/"
  @raw_filename_prefix "api.cardvault.fabtcg.com"

  defp priv_path(relative), do: Application.app_dir(:tabletop, relative)
  defp default_raw_dir, do: priv_path("priv/cards/raw")
  defp default_output_dir, do: priv_path("priv/cards/generated")

  @doc """
  Builds card snapshots from raw card-list pages.

  Options:
    * `:raw_path` – glob for raw card-list files (default: `priv/cards/raw/*.json`).
    * `:output_dir` – where snapshots go (default: `priv/cards/generated/`).
    * `:fetch_new` – when `true`, re-pulls the raw card list from cardvault
      before processing, overwriting `priv/cards/raw/api.cardvault.fabtcg.com-*.json`.
    * `:req_options` – passed through to `Req.get/2`.
  """
  def import_and_generate(opts \\ []) do
    raw_dir = Keyword.get(opts, :raw_dir, default_raw_dir())
    raw_path = Keyword.get(opts, :raw_path, Path.join(raw_dir, "*.json"))
    output_dir = Keyword.get(opts, :output_dir, default_output_dir())
    req_options = Keyword.get(opts, :req_options, [])

    if Keyword.get(opts, :fetch_new, false) do
      fetch_raw_card_list(raw_dir, req_options)
    end

    File.mkdir_p!(output_dir)

    Path.wildcard(raw_path)
    |> Enum.with_index(fn file, file_index ->
      {:ok, content} = File.read(file)
      {:ok, all_card_data} = Jason.decode(content)

      card_ids =
        all_card_data["results"]
        |> Enum.map(& &1["card_id"])
        |> Enum.uniq()

      Logger.info("Processing file #{file} with #{length(card_ids)} unique card IDs")

      api_results =
        card_ids
        |> Task.async_stream(fn card_id -> fetch_card(card_id, req_options) end,
          max_concurrency: @fetch_concurrency,
          timeout: @task_timeout,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, results} when is_list(results) -> results
          _ -> []
        end)
        |> Enum.uniq_by(& &1["id"])

      Logger.info("Fetched #{length(api_results)} api results from #{file}")

      cards =
        api_results
        |> Task.async_stream(fn result -> build_card_with_prints(result, req_options) end,
          max_concurrency: @phash_concurrency,
          timeout: @task_timeout,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, %{} = card_with_prints} -> [card_with_prints]
          {:ok, nil} -> []
          _ -> []
        end)

      out_file = Path.join(output_dir, "cards-#{file_index + 1}.json")

      Logger.info(
        "Writing #{length(cards)} cards (#{Enum.sum_by(cards, &length(&1.card_prints))} prints) -> #{out_file}"
      )

      File.write!(out_file, Jason.encode!(cards))

      if Keyword.get(opts, :insert, true) do
        insert_count = insert_cards(cards)
        Logger.info("Inserted #{insert_count} cards into the database from #{out_file}")
      end
    end)
  end

  defp insert_cards(cards) do
    Enum.reduce(cards, 0, fn card_data, acc ->
      case insert_card_with_prints(card_data) do
        {:ok, _} ->
          acc + 1

        {:error, reason} ->
          Logger.error("Failed to insert #{card_data.external_card_id}: #{inspect(reason)}")
          acc
      end
    end)
  end

  @doc """
  Reads generated JSON snapshots and inserts cards + card_prints.
  Skips a card if its `external_card_id` is already present.
  """
  def import_from_generated_data do
    Path.wildcard(priv_path("priv/cards/generated/*.json"))
    |> Enum.each(fn file ->
      Logger.info("Importing cards from file #{file}")
      {:ok, content} = File.read(file)
      # `keys: :atoms!` only converts to existing atoms — safe because every
      # key we use is referenced in the schema modules (Card / CardPrint /
      # ArtBboxDetector), so they're already loaded.
      {:ok, all_card_data} = Jason.decode(content, keys: :atoms!)

      Enum.each(all_card_data, fn card_data ->
        case insert_card_with_prints(card_data) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.error("Failed to insert card: #{inspect(reason)}")
        end
      end)
    end)
  end

  # --- Build a card+prints record from a single API result ---

  @doc false
  def build_card_with_prints(result, req_options \\ []) do
    faces = collect_english_faces(result["card_prints"])
    deduped = foil_dedup(faces)

    case canonical_face(deduped) do
      nil ->
        nil

      canonical ->
        prints =
          deduped
          |> Task.async_stream(fn face -> build_print(face, req_options) end,
            max_concurrency: 4,
            timeout: @task_timeout,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, %{} = print} -> [print]
            _ -> []
          end)

        %{
          external_card_id: result["id"],
          name: canonical["printed_name"],
          pitch: canonical["printed_pitch"],
          card_prints: prints
        }
    end
  end

  # --- Face collection & dedup ---
  
  def collect_english_faces(card_prints) when is_list(card_prints) do
    card_prints
    |> Enum.flat_map(fn card_print ->
      set_code = get_in(card_print, ["print_set", "set_code"])

      card_print["faces"]
      |> Enum.filter(&(&1["face_language"] == "en"))
      |> Enum.map(&Map.put(&1, "set_code", set_code))
    end)
  end

  def collect_english_faces(_), do: []

  @doc """
  Foil dedup rule. Group by `(set_code, art_type, layout_position)`. Within
  each group: prefer `finish_type == "regular"`. Otherwise keep one foil
  face (earliest by `face_id` for stability).
  """
  def foil_dedup(faces) do
    faces
    |> Enum.group_by(fn f -> {f["set_code"], f["art_type"], f["layout_position"]} end)
    |> Enum.map(fn {_key, group} ->
      case Enum.find(group, &(&1["finish_type"] == "regular")) do
        nil -> Enum.min_by(group, & &1["face_id"])
        regular -> regular
      end
    end)
  end

  defp canonical_face(faces) do
    Enum.find(faces, fn f ->
      f["art_type"] == "regular" and f["layout_position"] in [nil, 10]
    end) || List.first(faces)
  end

  # --- Per-face: download image, detect bbox, compute hashes ---

  defp build_print(face, req_options) do
    image_url = get_in(face, ["image", "large"])
    orientation = face["orientation"]
    art_type = face["art_type"]

    case download(image_url, req_options) do
      {:ok, image_binary} ->
        bbox = ArtBboxDetector.detect(image_binary, %{orientation: orientation, art_type: art_type})
        hashes = compute_hashes(image_binary, bbox, orientation)

        %{
          face_id: face["face_id"],
          set_code: face["set_code"],
          art_type: art_type,
          orientation: orientation,
          layout_position: face["layout_position"],
          is_canonical: art_type == "regular" and face["layout_position"] in [nil, 10],
          image_url: image_url,
          art_bbox: bbox,
          image_phash: hashes[:image_phash],
          image_phash_left: hashes[:image_phash_left],
          image_phash_right: hashes[:image_phash_right],
          image_phash_full: hashes[:image_phash_full]
        }

      :error ->
        nil
    end
  end

  defp compute_hashes(image_binary, %{halves: [left_bbox, right_bbox | _]}, _orientation) do
    %{
      image_phash_left: PHash.compute_from_binary(image_binary, bbox: bbox_tuple(left_bbox)),
      image_phash_right: PHash.compute_from_binary(image_binary, bbox: bbox_tuple(right_bbox)),
      image_phash_full: PHash.compute_from_binary(image_binary, bbox: {0.0, 0.0, 1.0, 1.0})
    }
  end

  defp compute_hashes(image_binary, %{x: _} = bbox, _orientation) do
    %{
      image_phash: PHash.compute_from_binary(image_binary, bbox: bbox_tuple(bbox)),
      image_phash_full: PHash.compute_from_binary(image_binary, bbox: {0.0, 0.0, 1.0, 1.0})
    }
  end

  defp compute_hashes(_image_binary, _bbox, _orientation), do: %{}

  defp bbox_tuple(%{"x" => x, "y" => y, "w" => w, "h" => h}), do: {x, y, w, h}
  defp bbox_tuple(%{x: x, y: y, w: w, h: h}), do: {x, y, w, h}

  defp download(nil, _opts), do: :error

  defp download(url, req_options) do
    case Req.get(url, [receive_timeout: 30_000, retry: :transient, max_retries: 2] ++ req_options) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("Importer: HTTP #{status} fetching #{url}")
        :error

      {:error, reason} ->
        Logger.warning("Importer: failed to fetch #{url}: #{inspect(reason)}")
        :error
    end
  end

  # --- DB insertion ---

  defp insert_card_with_prints(%{card_prints: prints} = card_data) when is_list(prints) do
    Tabletop.Repo.transaction(fn ->
      card =
        case Cards.find_by_external_card_id(card_data.external_card_id) do
          nil ->
            {:ok, c} =
              %Card{}
              |> Card.changeset(%{
                name: card_data.name,
                pitch: card_data.pitch,
                external_card_id: card_data.external_card_id
              })
              |> Tabletop.Repo.insert()

            c

          existing ->
            existing
        end

      Enum.each(prints, fn print_data ->
        attrs = Map.put(print_data, :card_id, card.id)

        case Cards.find_card_print_by_face_id(attrs.face_id) do
          nil ->
            %CardPrint{}
            |> CardPrint.changeset(attrs)
            |> Tabletop.Repo.insert!()

          _existing ->
            :ok
        end
      end)

      card
    end)
  end

  defp insert_card_with_prints(_), do: {:error, :invalid_shape}

  # --- API fetch ---

  @doc """
  Pages through the cardvault advanced-search endpoint and writes each page
  to `<raw_dir>/api.cardvault.fabtcg.com-<n>.json`. Existing files in
  `raw_dir` are removed first.

  Pulls all published cards (`is_published=true`).
  """
  def fetch_raw_card_list(raw_dir \\ nil, req_options \\ []) do
    raw_dir = raw_dir || default_raw_dir()
    File.mkdir_p!(raw_dir)

    Path.wildcard(Path.join(raw_dir, "#{@raw_filename_prefix}-*.json"))
    |> Enum.each(&File.rm!/1)

    Logger.info("Fetching raw card list from #{@raw_search_url}")
    fetch_raw_pages(raw_dir, 1, req_options)
  end

  defp fetch_raw_pages(raw_dir, page, req_options) do
    url =
      @raw_search_url <>
        "?format=json&is_published=true&orderby=name" <>
        "&page=#{page}&page_size=#{@raw_page_size}"

    case Req.get(url, [receive_timeout: 60_000, retry: :transient, max_retries: 3] ++ req_options) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        out_file = Path.join(raw_dir, "#{@raw_filename_prefix}-#{page}.json")
        File.write!(out_file, Jason.encode!(body))

        Logger.info(
          "Wrote page #{page}: #{length(body["results"] || [])} results -> #{Path.basename(out_file)}"
        )

        if body["next"] do
          fetch_raw_pages(raw_dir, page + 1, req_options)
        else
          :ok
        end

      {:ok, %{status: status}} ->
        Logger.error("fetch_raw_pages: HTTP #{status} on page #{page}, stopping")
        {:error, status}

      {:error, reason} ->
        Logger.error("fetch_raw_pages: failed page #{page}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_card(card_id, req_options) do
    url = "https://api.cardvault.fabtcg.com/carddb/api/v1/card_id/#{card_id}/"

    case Req.get(url, [receive_timeout: 15_000, retry: :transient, max_retries: 2] ++ req_options) do
      {:ok, %{status: 200, body: body}} ->
        body["results"] || []

      {:ok, %{status: status}} ->
        Logger.warning("Importer: HTTP #{status} fetching #{url}")
        []

      {:error, reason} ->
        Logger.warning("Importer: failed to fetch #{url}: #{inspect(reason)}")
        []
    end
  end
end
