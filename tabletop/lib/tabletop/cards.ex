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

  def find_by_p_hash_similarity(image_phash, threshold \\ 10) do
    from(c in Card,
      where:
        fragment("bit_count((? # ?)::bit(64))", c.image_phash, ^image_phash) < ^threshold,
      order_by: fragment("bit_count((? # ?)::bit(64))", c.image_phash, ^image_phash),
      limit: 5
    )
    |> Repo.all()
    |> IO.inspect(label: "find_by_p_hash_similarity")
  end

  @score_sql """
  similarity(?, ?) * 3
  + (SELECT count(*) FROM unnest(?::text[]) a(w) WHERE w = ANY(?::text[]))
  + (SELECT count(*) FROM (
       SELECT dmetaphone(w) FROM unnest(?::text[]) a(w)
       INTERSECT
       SELECT dmetaphone(w) FROM unnest(?::text[]) b(w)
     ) s)
  """

  def fuzzy_match_name(ocr_text) do
    normalized = OcrNormalizer.normalize(ocr_text)
    tokens = OcrNormalizer.tokens(ocr_text)

    from(c in Card,
      where:
        fragment("similarity(?, ?) > 0.1", c.normalized_name, ^normalized) or
          fragment("?::text[] && ?::text[]", c.tokens, ^tokens) or
          fragment(
            """
            ARRAY(SELECT dmetaphone(w) FROM unnest(?::text[]) a(w))
            && ARRAY(SELECT dmetaphone(w) FROM unnest(?::text[]) b(w))
            """,
            c.tokens,
            ^tokens
          ),
      order_by: [
        desc:
          fragment(
            @score_sql,
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
    |> IO.inspect(label: "fuzzy_match_name")
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
