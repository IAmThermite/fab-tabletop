defmodule Tabletop.Repo.Migrations.CreateCards do
  use Ecto.Migration

  def up do
    create table(:cards) do
      add :name, :string
      add :print_id, :string
      add :pitch, :integer
      add :image_url, :string
      add :normalized_name, :string
      add :tokens, {:array, :string}, default: []
      add :image_phash, :bigint

      timestamps(type: :utc_datetime)
    end

    create index(:cards, [:name])
    create unique_index(:cards, [:print_id])
    create index(:cards, [:normalized_name])
    create index(:cards, [:image_phash])
  end

  def down do
    drop index(:cards, [:image_phash])
    drop index(:cards, [:normalized_name])
    drop index(:cards, [:name])

    drop(table(:cards))
  end
end
