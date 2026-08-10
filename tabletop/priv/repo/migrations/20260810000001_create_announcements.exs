defmodule Tabletop.Repo.Migrations.CreateAnnouncements do
  use Ecto.Migration

  def change do
    create table(:announcements) do
      add :message, :text, null: false
      add :level, :string, null: false, default: "info"
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec
      add :dismissible, :boolean, null: false, default: true
      add :created_by_id, references(:users, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # `Tabletop.Announcements.active/0` runs on every LiveView mount and filters
    # on the display window, newest first — so the window bounds are what wants
    # indexing, not the creator.
    create index(:announcements, [:starts_at, :ends_at])
  end
end
