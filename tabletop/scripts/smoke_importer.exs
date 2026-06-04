# Run with: mix run scripts/smoke_importer.exs
#
# Builds a minimal raw card-list JSON containing the 4 example cards, runs
# import_and_generate to fetch + hash, then import_from_generated_data to
# insert into the DB. Verifies the rows look right.

require Logger

alias Tabletop.Cards
alias Tabletop.Cards.Importer

raw_dir = "/tmp/smoke_importer_raw"
out_dir = "/tmp/smoke_importer_out"
File.rm_rf!(raw_dir)
File.rm_rf!(out_dir)
File.mkdir_p!(raw_dir)
File.mkdir_p!(out_dir)

minimal_raw = %{
  "results" => [
    %{"card_id" => "arakni-5lp3d-7hru-7h3-cr4x"},
    %{"card_id" => "everbloom--life-3"},
    %{"card_id" => "great-library-of-solana"},
    %{"card_id" => "chum-friendly-first-mate-2"},
    %{"card_id" => "sink-below-1"}
  ]
}

File.write!(Path.join(raw_dir, "subset.json"), Jason.encode!(minimal_raw))

# Generate (fetch + hash)
Importer.import_and_generate(
  raw_path: Path.join(raw_dir, "*.json"),
  output_dir: out_dir
)

# Wipe DB then import from generated
Tabletop.Repo.delete_all(Tabletop.Cards.CardPrint)
Tabletop.Repo.delete_all(Tabletop.Cards.Card)

generated_files = Path.wildcard(Path.join(out_dir, "*.json"))
IO.puts("\nGenerated files: #{inspect(generated_files)}")

Enum.each(generated_files, fn file ->
  {:ok, content} = File.read(file)
  {:ok, data} = Jason.decode(content)
  IO.puts("\n#{file}: #{length(data)} cards")

  Enum.each(data, fn card_data ->
    n_prints = length(card_data["card_prints"] || [])
    IO.puts("  - #{card_data["external_card_id"]} #{inspect(card_data["name"])} (#{n_prints} prints)")
  end)
end)

# Insert
Enum.each(generated_files, fn file ->
  {:ok, content} = File.read(file)
  {:ok, data} = Jason.decode(content)

  Enum.each(data, fn card_data ->
    {:ok, card} =
      Tabletop.Repo.insert(
        Tabletop.Cards.Card.changeset(%Tabletop.Cards.Card{}, %{
          "name" => card_data["name"],
          "pitch" => card_data["pitch"],
          "external_card_id" => card_data["external_card_id"]
        })
      )

    Enum.each(card_data["card_prints"], fn print_data ->
      Tabletop.Repo.insert!(
        Tabletop.Cards.CardPrint.changeset(
          %Tabletop.Cards.CardPrint{},
          Map.put(print_data, "card_id", card.id)
        )
      )
    end)
  end)
end)

IO.puts("\n--- DB state ---")

import Ecto.Query

cards = Tabletop.Repo.all(from c in Tabletop.Cards.Card, preload: [:card_prints])

Enum.each(cards, fn card ->
  IO.puts("#{card.name} (pitch: #{card.pitch || "-"}, ext: #{card.external_card_id})")

  Enum.each(card.card_prints, fn cp ->
    hashes =
      [{:art, cp.image_phash}, {:full, cp.image_phash_full}]
      |> Enum.map(fn {k, v} -> "#{k}=#{if v, do: "✓", else: "·"}" end)
      |> Enum.join(" ")

    IO.puts("  - #{cp.face_id} | #{cp.orientation} | #{cp.art_type} | canon:#{cp.is_canonical} | #{hashes}")
  end)
end)
