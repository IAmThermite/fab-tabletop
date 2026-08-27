defmodule Tabletop.Repo.Migrations.RemoveDecklistFromGame do
  use Ecto.Migration

  def change do
    alter table(:games) do
      remove :decklist
    end
  end
end
