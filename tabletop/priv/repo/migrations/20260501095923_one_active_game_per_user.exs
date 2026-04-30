defmodule Tabletop.Repo.Migrations.OneActiveGamePerUser do
  use Ecto.Migration

  def change do
    create unique_index(:games, [:user_id],
             name: :games_one_active_per_user1,
             where: "status IN ('waiting','active') AND user1_left_at IS NULL"
           )

    create unique_index(:games, [:user2_id],
             name: :games_one_active_per_user2,
             where:
               "status IN ('waiting','active') AND user2_left_at IS NULL AND user2_id IS NOT NULL"
           )
  end
end
