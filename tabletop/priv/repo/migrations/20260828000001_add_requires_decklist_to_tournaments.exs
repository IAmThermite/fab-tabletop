defmodule Tabletop.Repo.Migrations.AddRequiresDecklistToTournaments do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      add :requires_decklist, :boolean, null: false, default: false
    end
  end
end
