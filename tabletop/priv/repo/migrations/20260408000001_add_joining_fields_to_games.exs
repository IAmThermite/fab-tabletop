defmodule Tabletop.Repo.Migrations.AddJoiningFieldsToGames do
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :joining_user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :joining_expires_at, :utc_datetime_usec
    end

    create index(:games, [:joining_user_id])
  end
end
