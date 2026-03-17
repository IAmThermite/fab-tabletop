defmodule Tabletop.Cards.Importer do
  @moduledoc """
  A module to import card data from JSON files into the database.
  """

  alias Tabletop.Cards
  alias Tabletop.Cards.Card

  def import do
    # read each json file in priv/cards and insert into the database
    Path.wildcard("priv/cards/*.json")
    |> Enum.each(fn file ->
      {:ok, content} = File.read(file)
      {:ok, all_card_data} = Jason.decode(content)

      Enum.each(all_card_data["results"], fn card_data ->
        card_struct = map_card_from_json(card_data)

        existing_card = Cards.find_by_name(card_struct.name)
        maybe_insert_card(existing_card, card_struct)
      end)
    end)
  end

  defp maybe_insert_card(nil, card_struct) do
    {:ok, _card} = Tabletop.Repo.insert(card_struct)
  end

  # skip if card already exists
  defp maybe_insert_card(card, _card_struct) do
    {:ok, card}
  end

  defp map_card_from_json(json) do
    %Card{
      name: json["printed_name"],
      image_url: get_in(json, ["faces", Access.at(0), "image", "large"])
    }
  end
end
