defmodule Tabletop.Repo.Migrations.DropCardPrintArtBboxAndLayoutPosition do
  use Ecto.Migration

  # pHashes are now imported precomputed from the flesh-and-blood-cards data set,
  # so the server no longer crops art at import time: `art_bbox` (the crop rect)
  # is obsolete. The source models each face as its own card entry, so
  # `layout_position` (the cardvault front/back-face marker) is no longer meaningful
  # either. Neither column is read at match or display time.
  def up do
    alter table(:card_prints) do
      remove :art_bbox
      remove :layout_position
    end
  end

  def down do
    alter table(:card_prints) do
      add :art_bbox, :map
      add :layout_position, :integer
    end
  end
end
