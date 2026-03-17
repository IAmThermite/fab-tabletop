defmodule Tabletop.Repo.Migrations.EnableMatchingExtensions do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS fuzzystrmatch")
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
      CREATE INDEX cards_name_trgm_idx
      ON cards
      USING GIN (normalized_name gin_trgm_ops)
    """)

    create index(:cards, [:tokens], using: "GIN")
  end

  def down do
    execute("DROP INDEX IF EXISTS cards_name_trgm_idx")
    drop(index(:cards, [:tokens], using: "GIN"))

    execute("DROP EXTENSION IF EXISTS fuzzystrmatch")
    execute("DROP EXTENSION IF EXISTS pg_trgm")
  end
end
