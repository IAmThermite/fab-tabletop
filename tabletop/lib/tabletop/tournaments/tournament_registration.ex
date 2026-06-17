defmodule Tabletop.Tournaments.TournamentRegistration do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @fabrary_regex ~r{\Ahttps://fabrary\.net/decks/[A-Za-z0-9\-_/]+\z}

  schema "tournament_registrations" do
    field :hero, :string
    field :decklist_url, :string
    field :seed, :integer
    field :dropped_at, :utc_datetime_usec
    field :checked_in_at, :utc_datetime_usec

    belongs_to :tournament, Tabletop.Tournaments.Tournament, type: Ecto.UUID
    belongs_to :user, Tabletop.Accounts.User, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  def changeset(reg, attrs) do
    reg
    |> cast(attrs, [:tournament_id, :user_id, :hero, :decklist_url])
    |> validate_required([:tournament_id, :user_id, :decklist_url])
    |> validate_format(:decklist_url, @fabrary_regex,
      message: "must be a Fabrary deck URL (https://fabrary.net/decks/...)"
    )
    |> unique_constraint([:tournament_id, :user_id])
  end

  def admin_changeset(reg, attrs) do
    reg
    |> cast(attrs, [:seed, :dropped_at, :checked_in_at])
  end
end
