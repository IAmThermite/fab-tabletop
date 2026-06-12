defmodule Tabletop.Cards do
  @moduledoc """
  The Cards context.

  After the schema split (see `Tabletop.Cards.Card` / `Tabletop.Cards.CardPrint`):

    * `Card` is the gameplay entity (name, pitch, rules-text identity).
    * `CardPrint` is a physical printing/face (image, art_type, orientation,
      pHashes).

  pHash matching queries `card_prints`; the manual name search queries `cards`
  and surfaces a canonical print for display.
  """

  import Ecto.Query, warn: false
  alias Tabletop.Repo

  alias Tabletop.Cards.{Card, CardPrint, OcrNormalizer}

  # Per-kind Hamming-distance thresholds. A row qualifies if **any** arm is
  # below its kind's threshold. Whole-card hashes are generous (frame/border
  # content is shared), so :full has its own stricter cap.
  @art_threshold 15
  @full_threshold 8

  # Sentinel returned by an arm that doesn't qualify — larger than any real
  # 64-bit Hamming distance, so it never wins LEAST during ranking.
  @miss_sentinel 65

  # --- Card lookups (gameplay identity) ---

  def find_all_by_name(name) do
    Repo.all(from c in Card, where: c.name == ^name)
    |> Repo.preload(:card_prints)
  end

  def find_by_external_card_id(external_card_id) do
    Repo.get_by(Card, external_card_id: external_card_id)
  end

  def find_card_by_face_id(face_id) do
    from(c in Card,
      join: cp in assoc(c, :card_prints),
      where: cp.face_id == ^face_id,
      preload: [card_prints: cp]
    )
    |> Repo.one()
  end

  # --- CardPrint lookups ---

  def find_card_print_by_face_id(face_id) do
    Repo.get_by(CardPrint, face_id: face_id)
    |> Repo.preload(:card)
  end

  @doc """
  Finds card_prints whose stored pHashes are close to one or more captured
  pHashes from the client.

  `phashes` is a map of `%{kind => integer | nil}` with kinds:
    * `:art`           — art crop
    * `:art_flipped`   — art crop, 180-rotated (orientation-uncertain)
    * `:full`          — whole-card hash

  Horizontal (landscape) cards are rotated to portrait by the scanner and
  matched the same way as vertical cards; the `:art`/`:art_flipped` pair
  absorbs the player's 180° flip.

  Per-kind thresholds:
    * `:art`, `:art_flipped` — Hamming distance < 15
    * `:full` — Hamming distance < 8 (whole-card hashes are generous due to
      shared frame/border content)

  Returns up to 5 `%CardPrint{}` rows preloaded with `:card`, ordered by the
  best (lowest) raw Hamming distance across all qualifying arms.
  """
  def find_by_p_hash_similarity(phashes) when is_map(phashes) do
    art = phashes[:art]
    art_flipped = phashes[:art_flipped]
    full = phashes[:full]

    miss = @miss_sentinel
    art_t = @art_threshold
    full_t = @full_threshold

    from(cp in CardPrint,
      where:
        fragment(
          """
          (? IS NOT NULL AND ?::bigint IS NOT NULL
              AND bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) < ?)
          OR (? IS NOT NULL AND ?::bigint IS NOT NULL
              AND bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) < ?)
          OR (? IS NOT NULL AND ?::bigint IS NOT NULL
              AND bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) < ?)
          """,
          # art vs image_phash
          cp.image_phash,
          type(^art, :integer),
          cp.image_phash,
          type(^art, :integer),
          ^art_t,
          # art_flipped vs image_phash
          cp.image_phash,
          type(^art_flipped, :integer),
          cp.image_phash,
          type(^art_flipped, :integer),
          ^art_t,
          # full vs image_phash_full
          cp.image_phash_full,
          type(^full, :integer),
          cp.image_phash_full,
          type(^full, :integer),
          ^full_t
        ),
      order_by:
        fragment(
          """
          LEAST(
            CASE WHEN ? IS NOT NULL AND ?::bigint IS NOT NULL
                      AND bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) < ?
                 THEN bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) ELSE ? END,
            CASE WHEN ? IS NOT NULL AND ?::bigint IS NOT NULL
                      AND bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) < ?
                 THEN bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) ELSE ? END,
            CASE WHEN ? IS NOT NULL AND ?::bigint IS NOT NULL
                      AND bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) < ?
                 THEN bit_count((?::bit(64) # ?::bigint::bit(64))::bit(64)) ELSE ? END
          )
          """,
          # art
          cp.image_phash,
          type(^art, :integer),
          cp.image_phash,
          type(^art, :integer),
          ^art_t,
          cp.image_phash,
          type(^art, :integer),
          ^miss,
          # art_flipped
          cp.image_phash,
          type(^art_flipped, :integer),
          cp.image_phash,
          type(^art_flipped, :integer),
          ^art_t,
          cp.image_phash,
          type(^art_flipped, :integer),
          ^miss,
          # full
          cp.image_phash_full,
          type(^full, :integer),
          cp.image_phash_full,
          type(^full, :integer),
          ^full_t,
          cp.image_phash_full,
          type(^full, :integer),
          ^miss
        ),
      preload: [:card],
      limit: 5
    )
    |> Repo.all()
  end

  # --- Pitch variants ---

  @doc """
  Returns the pitch variants of a card — distinct logical cards sharing
  `normalized_name` but differing by pitch. Each variant is preloaded with a
  canonical `card_print` (preferring `preferred_set_code`) for display.
  """
  def find_pitch_variants(%Card{normalized_name: name}, preferred_set_code \\ nil) do
    canonical_query =
      from cp in CardPrint,
        where: cp.is_canonical == true,
        order_by: [
          asc:
            fragment(
              "CASE WHEN ? = ? THEN 0 ELSE 1 END",
              cp.set_code,
              ^(preferred_set_code || "")
            )
        ]

    from(c in Card,
      where: c.normalized_name == ^name and not is_nil(c.pitch),
      order_by: [asc: c.pitch],
      preload: [card_prints: ^canonical_query]
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.pitch)
  end

  # --- Fuzzy text match against Card (manual name search) ---

  # Scoring formula:
  # - Trigram similarity of the full normalized name
  # - Token overlap: product of (card tokens found in query) × (query tokens found in card) × 4
  # - Phonetic matches (catches misspellings like CASARD → GUARD)
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

  def fuzzy_match_name(query_text) do
    normalized = OcrNormalizer.normalize(query_text)

    if String.length(normalized) < 3 || String.length(normalized) > 100 do
      []
    else
      fuzzy_match_normalized(normalized, OcrNormalizer.tokens(query_text))
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
            c.tokens,
            c.tokens,
            ^tokens,
            ^tokens,
            ^tokens,
            c.tokens,
            c.tokens,
            c.tokens,
            ^tokens
          )
      ],
      preload: [card_prints: ^canonical_print_query()],
      limit: 5
    )
    |> Repo.all()
  end

  defp canonical_print_query do
    from cp in CardPrint, where: cp.is_canonical == true
  end
end
