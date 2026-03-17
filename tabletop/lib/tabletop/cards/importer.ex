defmodule Tabletop.Cards.Importer do
  @moduledoc """
  A module to import card data from JSON files into the database.
  """

  require Logger

  alias Tabletop.Cards
  alias Tabletop.Cards.Card

  def import_and_generate do
    # read each json file in priv/cards/raw and insert into the database
    #
    Path.wildcard("priv/cards/raw/*.json")
    |> Enum.with_index(fn file, index ->
      {:ok, content} = File.read(file)
      {:ok, all_card_data} = Jason.decode(content)

      all_card_data["results"]
      |> Enum.flat_map(fn card_data ->
        fetch_card_prints(card_data["card_id"])
      end)
      |> Enum.map(fn card_data ->
        import_changeset_from_json(card_data)
      end)
      |> Enum.uniq_by(& &1.changes.image_phash)
      |> Enum.map(fn card_changeset ->
        existing_card = Cards.find_by_print_id(card_changeset.changes.print_id)
        maybe_insert_card(existing_card, card_changeset)
      end)
      |> Enum.map(fn {:ok, card} -> Cards.card_as_json_string(card) end)
      |> Enum.join(",")
      |> then(fn json_array ->
        "[#{json_array}]"
      end)
      |> then(fn json ->
        File.write!("priv/cards/generated/cards-#{index}.json", json)
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

  defp fetch_card_prints(card_id) do
    # fetch the card prints from the API and return the list of print ids
    url = "https://api.cardvault.fabtcg.com/carddb/api/v1/card_id/#{card_id}"

    {:ok, %{status: 200, body: body}} =
      Req.get(url, receive_timeout: 15_000, retry: :transient, max_retries: 2)

    dedupe_card_prints(body["results"])
  end

  # take only regular english printings of the card, and dedupe by face_id
  defp dedupe_card_prints(results) do
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

  defp import_changeset_from_json(face_json) do
    name = face_json["printed_name"]
    image_url = get_in(face_json, ["image", "large"])

    print_id = face_json["face_id"]

    %Card{}
    |> Card.import_changeset(%{name: name, image_url: image_url, print_id: print_id})
  end
end
