defmodule Tabletop.Repo.Migrations.AddLobbyActivityIndexes do
  use Ecto.Migration

  def change do
    # `Games.popular_heroes_by_format/1` aggregates a rolling window of recent
    # games; without this the window predicate is a full scan.
    create index(:games, [:inserted_at])

    # The lobby's open-games list (`list_joinable_games/2`) and its per-format
    # counts share these three predicates. The reservation check
    # (`joining_user_id`/`joining_expires_at`) is time-dependent, so it can't
    # live in the index and is applied to the small matching set instead.
    # `inserted_at` is the key column because the list orders by it.
    create index(:games, [:inserted_at],
             where: "status = 'waiting' AND private = false AND user2_id IS NULL",
             name: :games_open_lobby_index
           )

    # `active_game_stats/0` counts games in progress. Selective in the long run,
    # since finished games accumulate and active ones do not.
    create index(:games, [:status])
  end
end
