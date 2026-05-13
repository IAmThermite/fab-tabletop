defmodule Tabletop.Repo.Migrations.AddPrivateToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :private, :boolean, default: false, null: false
    end
  end
end
