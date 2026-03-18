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

  def find_by_p_hash_similarity(image_phash, threshold \\ 5) do
    hash =
      case image_phash do
        h when is_binary(h) -> String.to_integer(h)
        h -> h
      end

    from(c in Card,
      where: fragment("bit_count(? # ?)", c.image_phash, ^hash) < ^threshold,
      order_by: fragment("bit_count(? # ?)", c.image_phash, ^hash),
      limit: 5
    )
    |> Repo.all()
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
            + cardinality(?::text[] && ?::text[])
            + cardinality(
                ARRAY(
                  SELECT dmetaphone(word)
                  FROM unnest(?::text[]) AS word
                )
                &&
                ARRAY(
                  SELECT dmetaphone(word)
                  FROM unnest(?::text[]) AS word
                )
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
          fragment("?::text[] && ?::text[]", c.tokens, ^tokens) or
          fragment(
            """
            ARRAY(
              SELECT dmetaphone(word)
              FROM unnest(?::text[]) AS word
            )
            &&
            ARRAY(
              SELECT dmetaphone(word)
              FROM unnest(?::text[]) AS word
            )
            """,
            c.tokens,
            ^tokens
          ),
      order_by: [
        desc:
          fragment(
            """
            similarity(?, ?) * 3
            + cardinality(?::text[] && ?::text[])
            + cardinality(
                ARRAY(
                  SELECT dmetaphone(word)
                  FROM unnest(?::text[]) AS word
                )
                &&
                ARRAY(
                  SELECT dmetaphone(word)
                  FROM unnest(?::text[]) AS word
                )
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

  def list_cards do
    Repo.all(Card)
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
