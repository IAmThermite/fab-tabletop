defmodule Tabletop.Repo.Migrations.AddLanguageToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      # NOT NULL with a default so existing rows backfill to the default
      # language (English). Derived from Tabletop.Languages so it can't drift
      # from the schema default.
      add :language, :string, null: false, default: to_string(Tabletop.Languages.default())
    end
  end
end
