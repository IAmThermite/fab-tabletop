defmodule Tabletop.Cards.Importer do
  @moduledoc """
  Imports Flesh and Blood card data from the `flesh-and-blood-cards` data set,
  vendored as a git submodule under `vendor/flesh-and-blood-cards`.

  That data set ships precomputed perceptual hashes (`phash_art`, `phash_full`)
  generated with the same DCT / art-bbox / threshold algorithm as
  `Tabletop.Cards.PHash` and `assets/js/card_scanner/p_hash.js`. So this importer
  does no image downloading or hashing: it reads `json/english/card.json`,
  transforms each card + its printings, and inserts directly into Postgres.

  `import_all/1` upserts on `cards.external_card_id` and `card_prints.face_id`:
  re-running adds new cards/prints and updates existing ones in place (so upstream
  corrections — a fixed pHash, a renamed card, a changed image — propagate). It
  does not delete rows that vanish upstream.

  Mapping highlights:
    * `face_id` comes from a printing's `unique_id` (globally unique). The shorter
      `id` (e.g. `"MST131"`) is NOT image-unique across editions/foilings.
    * Foiling variants that share an image (same `phash_full`) collapse to one
      print, preferring the standard (`"S"`) finish. A cold-foil print whose image
      genuinely differs survives as its own print with its own hashes.
    * Exactly one print per card is marked `is_canonical` (regular art, standard
      foiling, earliest in source order).
  """

  require Logger

  alias Tabletop.Cards
  alias Tabletop.Cards.{Card, CardPrint}
  alias Tabletop.Repo

  # Preference order when collapsing foiling variants and picking the canonical
  # print. Lower is better; anything not listed (cold "C", gold "G") sorts last.
  @foil_rank %{"S" => 0, "R" => 1}

  @doc """
  Reads the card data set and inserts cards + prints. Returns `{inserted, skipped}`.

  Options:
    * `:source` — path to `card.json`. Defaults to the configured/vendored path
      (see `source_path/0`).
  """
  def import_all(opts \\ []) do
    path = Keyword.get(opts, :source) || source_path()
    Logger.info("Importing cards from #{path}")

    {:ok, content} = File.read(path)
    {:ok, cards} = Jason.decode(content)

    {inserted, skipped} =
      Enum.reduce(cards, {0, 0}, fn card_json, {ins, skip} ->
        case build_card(card_json) do
          nil ->
            {ins, skip + 1}

          card_attrs ->
            case upsert_card_with_prints(card_attrs) do
              {:ok, _} ->
                {ins + 1, skip}

              {:error, reason} ->
                Logger.error(
                  "Failed to insert #{card_attrs.external_card_id}: #{inspect(reason)}"
                )

                {ins, skip + 1}
            end
        end
      end)

    Logger.info("Imported #{inserted} cards (#{skipped} skipped)")
    {inserted, skipped}
  end

  @doc """
  Resolves the path to `card.json`.

  In a release the file is bundled into `priv/cards/card.json` (copied from the
  submodule at build time); otherwise it falls back to the submodule's working
  tree at the repo root. Override with the `:card_source_path` app env or the
  `:source` option to `import_all/1`.
  """
  def source_path do
    Application.get_env(:tabletop, :card_source_path) || default_source_path()
  end

  defp default_source_path do
    bundled = Application.app_dir(:tabletop, "priv/cards/card.json")

    if File.exists?(bundled) do
      bundled
    else
      Path.expand("../vendor/flesh-and-blood-cards/json/english/card.json", File.cwd!())
    end
  end

  # --- Transform: card.json entry -> card attrs with embedded prints ---

  @doc false
  def build_card(%{"unique_id" => external_id, "name" => name, "printings" => printings} = card)
      when is_list(printings) do
    orientation = if card["played_horizontally"], do: "horizontal", else: "vertical"

    prints =
      printings
      |> Enum.with_index()
      |> Enum.flat_map(fn {printing, index} -> build_print(printing, orientation, index) end)
      |> dedup_by_image()
      |> mark_canonical()

    case prints do
      # Every printing was imageless — nothing to scan or display, skip the card.
      [] ->
        nil

      _ ->
        %{
          external_card_id: external_id,
          name: name,
          pitch: parse_pitch(card["pitch"]),
          card_prints: prints
        }
    end
  end

  def build_card(_), do: nil

  # Imageless printings can't be inserted (the changeset requires `:image_url`)
  # and carry no hashes to match against — drop them.
  defp build_print(%{"image_url" => url} = printing, orientation, index) when is_binary(url) do
    [
      %{
        face_id: printing["unique_id"],
        set_code: printing["set_id"],
        art_type: art_type(printing["art_variations"]),
        orientation: orientation,
        image_url: url,
        # `phash_art` is absent for horizontal prints -> nil (full arm still matches).
        image_phash: parse_phash(printing["phash_art"]),
        image_phash_full: parse_phash(printing["phash_full"]),
        # Transient ranking fields, stripped before insert.
        foiling: printing["foiling"],
        source_index: index
      }
    ]
  end

  defp build_print(_printing, _orientation, _index), do: []

  # Collapse printings that share an image (identical `phash_full`) to one print,
  # preferring the standard finish. Prints with genuinely different images (e.g. a
  # distinct cold-foil art) stay separate. Result is ordered by source index.
  defp dedup_by_image(prints) do
    prints
    |> Enum.group_by(& &1.image_phash_full)
    |> Enum.map(fn {_phash, group} -> Enum.min_by(group, &foil_key/1) end)
    |> Enum.sort_by(& &1.source_index)
  end

  # Mark exactly one print canonical: regular art, then standard foiling, then
  # earliest in source order.
  defp mark_canonical([]), do: []

  defp mark_canonical(prints) do
    canonical = Enum.min_by(prints, &canonical_key/1)
    Enum.map(prints, &Map.put(&1, :is_canonical, &1.face_id == canonical.face_id))
  end

  defp foil_key(print), do: {Map.get(@foil_rank, print.foiling, 2), print.source_index}

  defp canonical_key(print) do
    {if(print.art_type == "regular", do: 0, else: 1), Map.get(@foil_rank, print.foiling, 2),
     print.source_index}
  end

  defp art_type([]), do: "regular"

  defp art_type(variations) when is_list(variations),
    do: if("FA" in variations, do: "full_art", else: "alternate")

  defp art_type(_), do: "regular"

  defp parse_pitch(p) when is_integer(p), do: p
  defp parse_pitch(p) when is_binary(p), do: parse_int(p)
  defp parse_pitch(_), do: nil

  defp parse_phash(p) when is_integer(p), do: p
  defp parse_phash(p) when is_binary(p), do: parse_int(p)
  defp parse_phash(_), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  # --- DB upsert (keyed on external_card_id + face_id) ---

  # We already look up each row by its unique key, so insert-or-update on the
  # existing struct is the simplest upsert: it preserves ids/timestamps, re-runs
  # the changeset (recomputing `normalized_name`/`tokens` on a card, refreshing
  # hashes/canonical on a print), and avoids `on_conflict` RETURNING subtleties.
  defp upsert_card_with_prints(%{card_prints: prints} = card_data) do
    Repo.transaction(fn ->
      card = upsert_card(card_data)

      Enum.each(prints, fn print ->
        attrs =
          print
          |> Map.drop([:foiling, :source_index])
          |> Map.put(:card_id, card.id)

        (Cards.find_card_print_by_face_id(attrs.face_id) || %CardPrint{})
        |> CardPrint.changeset(attrs)
        |> Repo.insert_or_update!()
      end)

      card
    end)
  end

  defp upsert_card(card_data) do
    (Cards.find_by_external_card_id(card_data.external_card_id) || %Card{})
    |> Card.changeset(%{
      name: card_data.name,
      pitch: card_data.pitch,
      external_card_id: card_data.external_card_id
    })
    |> Repo.insert_or_update!()
  end
end
