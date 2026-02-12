defmodule Tabletop.Repo.Migrations.CreateGames do
  use Ecto.Migration

  def change do
    create table(:games) do
      add :title, :string
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :user2_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :format, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:games, [:user_id])
    create index(:games, [:user2_id])
    create index(:games, [:format])
  end
end
