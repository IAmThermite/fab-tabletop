defmodule Tabletop.Repo.Migrations.CreateGameStates do
  use Ecto.Migration

  def change do
    create table(:game_states, primary_key: false) do
      add :game_id, references(:games, type: :uuid, on_delete: :delete_all), primary_key: true
      add :state, :map, default: %{}

      timestamps()
    end
  end
end
