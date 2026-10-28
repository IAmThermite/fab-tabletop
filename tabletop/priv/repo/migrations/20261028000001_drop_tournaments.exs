defmodule Tabletop.Repo.Migrations.DropTournaments do
  use Ecto.Migration

  # The tournament feature was removed. Games that were created as tournament
  # matches stay in `games` as ordinary (hero-less) rows; only the tournament
  # tables themselves go. Irreversible: the data is not recoverable from here.
  def up do
    drop_if_exists table(:tournament_matches)
    drop_if_exists table(:tournament_registrations)

    # `tournaments.current_round_id` and `tournament_rounds.tournament_id`
    # reference each other, so break the cycle before dropping either table.
    alter table(:tournaments) do
      remove_if_exists :current_round_id, :uuid
    end

    drop_if_exists table(:tournament_rounds)
    drop_if_exists table(:tournaments)
  end

  def down do
    raise Ecto.MigrationError,
          "tournaments were removed; restore them from 20260423000001_create_tournaments.exs"
  end
end
