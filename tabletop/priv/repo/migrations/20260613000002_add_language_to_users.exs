defmodule Tabletop.Repo.Migrations.AddLanguageToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Optional preference — nullable, no default.
      add :language, :string
    end
  end
end
