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

  def find_all_by_name(name) do
    Repo.all(from c in Card, where: c.name == ^name)
  end

  def find_by_print_id(print_id) do
    Repo.get_by(Card, print_id: print_id)
  end

  def find_by_p_hash_similarity(image_phash, threshold \\ 15) do
    from(c in Card,
      where: fragment("bit_count((? # ?)::bit(64))", c.image_phash, ^image_phash) < ^threshold,
      order_by: fragment("bit_count((? # ?)::bit(64))", c.image_phash, ^image_phash),
      limit: 5
    )
    |> Repo.all()
    |> IO.inspect(label: "find_by_p_hash_similarity")
  end

  @doc """
  Try both orientations' pHashes and return the result set with the better top match.
  Used when the client can't determine card orientation.
  """
  def find_by_p_hash_similarity_dual(phash, phash_flipped, threshold \\ 15) do
    results_a = find_by_p_hash_similarity(phash, threshold)
    results_b = find_by_p_hash_similarity(phash_flipped, threshold)

    best_a = best_hamming_distance(results_a, phash)
    best_b = best_hamming_distance(results_b, phash_flipped)

    if best_b < best_a, do: results_b, else: results_a
  end

  defp best_hamming_distance([], _phash), do: 64

  defp best_hamming_distance(results, phash) do
    results
    |> Enum.map(fn card ->
      Bitwise.bxor(card.image_phash, phash)
      |> Integer.digits(2)
      |> Enum.count(&(&1 == 1))
    end)
    |> Enum.min()
  end

  # Scoring formula:
  # - Trigram similarity of the full normalized name (good for close matches)
  # - Token overlap: product of (card tokens found in query) × (query tokens found in card) × 4
  #   Using the product rewards complete mutual coverage — "Bravo" scores 1.0 against the card
  #   "Bravo" but only 0.5 against "Bravo, Flattering Showman" (which has 2 extra tokens the query lacks)
  # - Phonetic matches (catches misspellings like CASARD→GUARD)
  @score_sql """
  similarity(?, ?) * 2
  + (SELECT count(*)::float / GREATEST(array_length(?, 1), 1) FROM unnest(?::text[]) a(w) WHERE w = ANY(?::text[]))
    * (SELECT count(*)::float / GREATEST(array_length(?::text[], 1), 1) FROM unnest(?::text[]) a(w) WHERE w = ANY(?::text[]))
    * 4
  + (SELECT count(*)::float / GREATEST(array_length(?, 1), 1) FROM (
       SELECT dmetaphone(w) FROM unnest(?::text[]) a(w)
       INTERSECT
       SELECT dmetaphone(w) FROM unnest(?::text[]) b(w)
     ) s) * 2
  """

  def fuzzy_match_name(ocr_text) do
    normalized = OcrNormalizer.normalize(ocr_text)

    if String.length(normalized) < 3 do
      []
    else
      fuzzy_match_normalized(normalized, OcrNormalizer.tokens(ocr_text))
    end
  end

  defp fuzzy_match_normalized(normalized, tokens) do
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
            # card coverage: denominator (card token count)
            c.tokens,
            # card coverage: iterate card tokens
            c.tokens,
            # card coverage: match against query tokens
            ^tokens,
            # query coverage: denominator (query token count)
            ^tokens,
            # query coverage: iterate query tokens
            ^tokens,
            # query coverage: match against card tokens
            c.tokens,
            # phonetic: denominator
            c.tokens,
            # phonetic: card tokens
            c.tokens,
            # phonetic: query tokens
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

  def find_pitch_variants(card, preferred_set_code \\ nil) do
    from(c in Card,
      where: c.normalized_name == ^card.normalized_name and not is_nil(c.pitch),
      order_by: [
        {:asc, c.pitch},
        {:asc, fragment("CASE WHEN ? = ? THEN 0 ELSE 1 END", c.set_code, ^preferred_set_code)}
      ]
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.pitch)
  end

  def card_as_json_string(card) do
    %{
      name: card.name,
      print_id: card.print_id,
      normalized_name: card.normalized_name,
      tokens: card.tokens,
      image_url: card.image_url,
      image_phash: card.image_phash,
      pitch: card.pitch,
      set_code: card.set_code
    }
    |> Jason.encode!()
  end
end
