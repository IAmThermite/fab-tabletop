defmodule Tabletop.Repo.Migrations.CreateCards do
  use Ecto.Migration

  def change do
    create table(:cards) do
      add :name, :string
      add :image_url, :string

      timestamps(type: :utc_datetime)
    end
  end
end
