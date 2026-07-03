defmodule Tabletop.Repo.Migrations.AddHeroAndCompetitiveToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :user2_hero, :string
      add :competitive, :boolean, default: false, null: false
    end
  end
end
