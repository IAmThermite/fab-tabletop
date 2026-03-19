defmodule Tabletop.Cards.Importer do
  @moduledoc """
  A module to import card data from JSON files into the database.
  """

  require Logger

  alias Tabletop.Cards
  alias Tabletop.Cards.Card

  @fetch_concurrency 10
  @phash_concurrency 15
  @task_timeout :timer.seconds(60)

  @default_raw_path "priv/cards/raw/*.json"
  @default_output_dir "priv/cards/generated"

  def import_and_generate(opts \\ []) do
    raw_path = Keyword.get(opts, :raw_path, @default_raw_path)
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    req_options = Keyword.get(opts, :req_options, [])

    Path.wildcard(raw_path)
    |> Enum.with_index(fn file, file_index ->
      {:ok, content} = File.read(file)
      {:ok, all_card_data} = Jason.decode(content)

      card_ids =
        all_card_data["results"]
        |> Enum.map(& &1["card_id"])
        |> Enum.uniq()

      Logger.info("Processing file #{file} with #{length(card_ids)} unique card IDs")

      faces =
        card_ids
        |> Task.async_stream(fn card_id -> fetch_card_prints(card_id, req_options) end,
          max_concurrency: @fetch_concurrency,
          timeout: @task_timeout,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, prints} -> prints
          {:exit, _reason} -> []
        end)

      Logger.info(
        "Fetched #{length(Enum.concat(faces))} unique card faces for #{length(card_ids)} card IDs in file #{file}"
      )

      faces
      |> Task.async_stream(fn face -> import_changeset_from_json(face, req_options) end,
        max_concurrency: @phash_concurrency,
        timeout: @task_timeout,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, changeset} -> [changeset]
        {:exit, _reason} -> []
      end)
      |> Enum.uniq_by(fn cs -> {cs.changes.image_phash, cs.changes[:pitch]} end)
      |> then(fn unique_cards ->
        Logger.info("Generated #{length(unique_cards)} unique cards from file #{file}")
        unique_cards
      end)
      |> Enum.chunk_every(100)
      |> Enum.with_index(fn chunk, chunk_index ->
        Logger.info("Processing chunk #{chunk_index + 1} from file #{file}")

        chunk
        |> Enum.map(fn card_changeset ->
          existing_card = Cards.find_by_print_id(card_changeset.changes.print_id)
          maybe_insert_card(existing_card, card_changeset)
        end)
      end)
      |> List.flatten()
      |> Enum.map(fn {:ok, card} -> Cards.card_as_json_string(card) end)
      |> Enum.join(",")
      |> then(fn json_array ->
        "[#{json_array}]"
      end)
      |> then(fn json ->
        Logger.info(
          "Writing generated data for file #{file_index + 1} with #{length(faces)} faces"
        )

        File.write!("#{output_dir}/cards-#{file_index + 1}.json", json)
      end)
    end)
  end

  # read from generated/cards.json and insert into the database
  def import_from_generated_data do
    {:ok, content} = File.read("priv/cards/generated/cards.json")
    {:ok, all_card_data} = Jason.decode(content)

    Enum.each(all_card_data, fn card_data ->
      {:ok, _card} =
        %Card{}
        |> Card.generated_changeset(card_data)
        |> Tabletop.Repo.insert()
    end)
  end

  def export_to_json do
    Cards.list_cards()
    |> Enum.map(&Cards.card_as_json_string/1)
    |> Enum.chunk_every(1000)
    |> Enum.join(",")
    |> Enum.with_index(fn chunk, index ->
      File.write!("priv/cards/generated/cards-exported-#{index}.json", "[#{chunk}]")
    end)
  end

  defp fetch_card_prints(card_id, req_options) do
    url = "https://api.cardvault.fabtcg.com/carddb/api/v1/card_id/#{card_id}/"

    {:ok, %{status: 200, body: body}} =
      Req.get(url, [receive_timeout: 15_000, retry: :transient, max_retries: 2] ++ req_options)

    dedupe_card_prints(body["results"])
  end

  @doc false
  def dedupe_card_prints(results) do
    results
    |> Enum.flat_map(& &1["card_prints"])
    |> Enum.flat_map(& &1["faces"])
    |> Enum.uniq_by(& &1["face_id"])
    |> Enum.reject(&(&1["face_language"] != "en"))
    |> Enum.reject(&(&1["finish_type"] != "regular"))
    |> Enum.reject(&(&1["art_type"] != "regular"))
  end

  defp maybe_insert_card(nil, card_changeset) do
    {:ok, _card} = Tabletop.Repo.insert(card_changeset)
  end

  # skip if card already exists
  defp maybe_insert_card(card, _card_changeset) do
    {:ok, card}
  end

  @doc false
  def import_changeset_from_json(face_json, req_options \\ []) do
    name = face_json["printed_name"]
    image_url = get_in(face_json, ["image", "large"])
    print_id = face_json["face_id"]
    pitch = face_json["printed_pitch"]

    %Card{}
    |> Card.import_changeset(
      %{name: name, image_url: image_url, print_id: print_id, pitch: pitch},
      req_options: req_options
    )
  end
end
