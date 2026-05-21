defmodule Tabletop.Games.GameState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:game_id, Ecto.UUID, autogenerate: false}

  schema "game_states" do
    field :state, :map, default: %{}
    belongs_to :game, Tabletop.Games.Game, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  def changeset(game_state, attrs) do
    game_state
    |> cast(attrs, [:state, :game_id])
    |> validate_required([:game_id, :state])
  end
end
