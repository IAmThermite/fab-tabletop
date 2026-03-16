defmodule Tabletop.Cards do
  @moduledoc """
  The Cards context.
  """

  import Ecto.Query, warn: false
  alias Tabletop.Repo

  alias Tabletop.Cards.Card

  def find_by_name(name) do
    Repo.get_by(Card, name: name)
  end

  def fuzzy_match_name(name) do
    pattern = "%#{name}%"

    Repo.all(
      from c in Card,
        where: ilike(c.name, ^pattern),
        order_by: [asc: c.name],
        limit: 10
    )
  end

  def populate_cards do
    Tabletop.CardImporter.import()
  end
end
