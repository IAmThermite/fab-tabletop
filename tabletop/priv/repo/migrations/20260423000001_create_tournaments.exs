defmodule Tabletop.Repo.Migrations.CreateTournaments do
  use Ecto.Migration

  def change do
    create table(:tournaments) do
      add :name, :string, null: false
      add :description, :text
      add :format, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :max_players, :integer, null: false, default: 32
      add :swiss_rounds, :integer, null: false, default: 4
      add :top_cut_size, :integer, null: false, default: 8
      add :round_duration_seconds, :integer, null: false, default: 3300
      add :starts_at, :utc_datetime_usec
      add :created_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :winner_id, references(:users, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:tournaments, [:status])
    create index(:tournaments, [:created_by_id])

    create table(:tournament_rounds) do
      add :tournament_id,
          references(:tournaments, type: :uuid, on_delete: :delete_all),
          null: false

      add :round_number, :integer, null: false
      add :kind, :string, null: false, default: "swiss"
      add :cut_stage, :integer
      add :started_at, :utc_datetime_usec
      add :deadline_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournament_rounds, [:tournament_id, :round_number])

    alter table(:tournaments) do
      add :current_round_id,
          references(:tournament_rounds, type: :uuid, on_delete: :nilify_all)
    end

    create table(:tournament_registrations) do
      add :tournament_id,
          references(:tournaments, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :hero, :string
      add :decklist_url, :string
      add :seed, :integer
      add :dropped_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournament_registrations, [:tournament_id, :user_id])
    create index(:tournament_registrations, [:user_id])

    create table(:tournament_matches) do
      add :tournament_id,
          references(:tournaments, type: :uuid, on_delete: :delete_all),
          null: false

      add :round_id,
          references(:tournament_rounds, type: :uuid, on_delete: :delete_all),
          null: false

      add :table_number, :integer
      add :player1_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :player2_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :player1_reported, :string
      add :player2_reported, :string
      add :player1_games_won, :integer
      add :player2_games_won, :integer
      add :confirmed_result, :string
      add :confirmed_at, :utc_datetime_usec
      add :confirmed_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :game_id, references(:games, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:tournament_matches, [:tournament_id, :round_id])
    create index(:tournament_matches, [:player1_id])
    create index(:tournament_matches, [:player2_id])
  end
end
