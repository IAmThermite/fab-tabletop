defmodule Tabletop.Tournaments.TournamentRound do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "tournament_rounds" do
    field :round_number, :integer
    field :kind, Ecto.Enum, values: [:swiss, :top_cut], default: :swiss
    field :cut_stage, :integer
    field :started_at, :utc_datetime_usec
    field :deadline_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :tournament, Tabletop.Tournaments.Tournament, type: Ecto.UUID
    has_many :matches, Tabletop.Tournaments.TournamentMatch, foreign_key: :round_id

    timestamps(type: :utc_datetime)
  end

  def changeset(round, attrs) do
    round
    |> cast(attrs, [
      :tournament_id,
      :round_number,
      :kind,
      :cut_stage,
      :started_at,
      :deadline_at,
      :completed_at
    ])
    |> validate_required([:tournament_id, :round_number, :kind])
    |> unique_constraint([:tournament_id, :round_number])
  end
end
