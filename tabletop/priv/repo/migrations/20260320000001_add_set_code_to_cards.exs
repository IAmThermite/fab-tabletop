defmodule Tabletop.Repo.Migrations.AddSetCodeToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :set_code, :string
    end
  end
end
