defmodule Tabletop.Cards do
  @moduledoc """
  The Cards context.
  """

  import Ecto.Query, warn: false
  alias Tabletop.Repo

  alias Tabletop.Cards.{Card, OcrNormalizer}

  def find_by_name(name) do
    Repo.get_by(Card, name: name)
  end

  def find_by_print_id(print_id) do
    Repo.get_by(Card, print_id: print_id)
  end

  def list_cards do
    Repo.all(Card)
  end

  def fuzzy_match_name(ocr_text) do
    normalized = OcrNormalizer.normalize(ocr_text)
    tokens = OcrNormalizer.tokens(ocr_text)

    from(c in Card,
      select: %{
        id: c.id,
        name: c.name,
        score:
          fragment(
            """
            similarity(?, ?) * 3
            + cardinality(? && ?::text[])
            + cardinality(
                ARRAY(SELECT dmetaphone(unnest(?)))
                && ARRAY(SELECT dmetaphone(unnest(?::text[])))
              )
            """,
            c.normalized_name,
            ^normalized,
            c.tokens,
            ^tokens,
            c.tokens,
            ^tokens
          )
      },
      where:
        fragment("similarity(?, ?) > 0.1", c.normalized_name, ^normalized) or
          fragment("? && ?::text[]", c.tokens, ^tokens) or
          fragment(
            "ARRAY(SELECT dmetaphone(unnest(?))) && ARRAY(SELECT dmetaphone(unnest(?::text[])))",
            c.tokens,
            ^tokens
          ),
      order_by: [
        desc:
          fragment(
            """
            similarity(?, ?) * 3
            + cardinality(? && ?::text[])
            + cardinality(
                ARRAY(SELECT dmetaphone(unnest(?)))
                && ARRAY(SELECT dmetaphone(unnest(?::text[])))
              )
            """,
            c.normalized_name,
            ^normalized,
            c.tokens,
            ^tokens,
            c.tokens,
            ^tokens
          )
      ],
      limit: 5
    )
    |> Repo.all()
  end

  def card_as_json_string(card) do
    %{
      name: card.name,
      print_id: card.print_id,
      normalized_name: card.normalized_name,
      tokens: card.tokens,
      image_url: card.image_url,
      image_phash: card.image_phash
    }
    |> Jason.encode!()
  end
end
