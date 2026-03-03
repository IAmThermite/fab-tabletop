defmodule Tabletop.Repo.Migrations.CreateGames do
  use Ecto.Migration

  def change do
    create table(:games) do
      add :title, :string
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :user2_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :format, :string, null: false
      add :hero, :string
      add :decklist, :string
      add :status, :string, null: false, default: "waiting"
      add :user1_left_at, :utc_datetime_usec
      add :user2_left_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create index(:games, [:user_id])
    create index(:games, [:user2_id])
    create index(:games, [:format])
  end
end
