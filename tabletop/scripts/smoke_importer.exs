# Run with: mix run scripts/smoke_importer.exs
#
# Writes a minimal `card.json`-shaped fixture (a handful of cards covering
# foil dedup, full art, and a horizontal/meld card), runs `import_all/1` against
# it, then prints the resulting DB rows to eyeball.

require Logger

import Ecto.Query

alias Tabletop.Cards.Importer
alias Tabletop.Repo
alias Tabletop.Cards.{Card, CardPrint}

source = "/tmp/smoke_importer_card.json"

fixture = [
  %{
    "unique_id" => "smoke-reunion",
    "name" => "10,000 Year Reunion",
    "pitch" => "1",
    "played_horizontally" => false,
    "printings" => [
      # Standard + rainbow foil share an image -> collapse to one (standard) print.
      %{"unique_id" => "smoke-mst131-s", "id" => "MST131", "set_id" => "MST", "foiling" => "S",
        "art_variations" => [], "image_url" => "https://example.com/MST131.png",
        "phash_art" => "414447273410687721", "phash_full" => "1535517334068017902"},
      %{"unique_id" => "smoke-mst131-r", "id" => "MST131", "set_id" => "MST", "foiling" => "R",
        "art_variations" => [], "image_url" => "https://example.com/MST131.png",
        "phash_art" => "414447273410687721", "phash_full" => "1535517334068017902"},
      # Full-art extended print, different image -> kept, non-canonical.
      %{"unique_id" => "smoke-lgs-fa", "id" => "LGS282", "set_id" => "LGS", "foiling" => "R",
        "art_variations" => ["FA"], "image_url" => "https://example.com/LGS282.webp",
        "phash_art" => "1113222196439007402", "phash_full" => "6082765317465521772"}
    ]
  },
  %{
    "unique_id" => "smoke-meld",
    "name" => "Arcane Seeds // Life",
    "pitch" => "1",
    "played_horizontally" => true,
    "printings" => [
      # Horizontal: no phash_art -> image_phash nil, full only.
      %{"unique_id" => "smoke-flr013", "id" => "FLR013", "set_id" => "FLR", "foiling" => "S",
        "art_variations" => [], "image_url" => "https://example.com/FLR013.webp",
        "phash_full" => "416679960560757700"}
    ]
  },
  %{
    "unique_id" => "smoke-noimage",
    "name" => "Imageless Card",
    "pitch" => "",
    "played_horizontally" => false,
    # All prints imageless -> card skipped entirely.
    "printings" => [
      %{"unique_id" => "smoke-noimg-1", "id" => "XXX001", "set_id" => "XXX", "foiling" => "S",
        "art_variations" => [], "image_url" => nil, "phash_full" => nil}
    ]
  }
]

File.write!(source, Jason.encode!(fixture))

# Clear, import, then re-import to demonstrate idempotency.
Repo.delete_all(CardPrint)
Repo.delete_all(Card)

{inserted, skipped} = Importer.import_all(source: source)
IO.puts("\nimport_all: inserted=#{inserted} skipped=#{skipped}")

{again, _} = Importer.import_all(source: source)
IO.puts("import_all (re-run): inserted=#{again} (idempotent — no new prints)")

IO.puts("\n--- DB state ---")

Repo.all(from c in Card, preload: [:card_prints])
|> Enum.each(fn card ->
  IO.puts("#{card.name} (pitch: #{card.pitch || "-"}, ext: #{card.external_card_id})")

  Enum.each(card.card_prints, fn cp ->
    hashes =
      [{:art, cp.image_phash}, {:full, cp.image_phash_full}]
      |> Enum.map(fn {k, v} -> "#{k}=#{if v, do: "✓", else: "·"}" end)
      |> Enum.join(" ")

    IO.puts("  - #{cp.face_id} | #{cp.set_code} | #{cp.orientation} | #{cp.art_type} | canon:#{cp.is_canonical} | #{hashes}")
  end)
end)
