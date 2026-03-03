defmodule Tabletop.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @valid_formats %{
    classic_constructed: "Classic Constructed",
    silver_age: "Silver Age",
    living_legend: "Living Legend"
  }

  schema "games" do
    field :title, :string
    field :format, Ecto.Enum, values: Map.keys(@valid_formats), default: :classic_constructed
    field :hero, :string
    field :decklist, :string
    field :status, Ecto.Enum, values: [:waiting, :active, :finished], default: :waiting
    field :user1_left_at, :utc_datetime_usec
    field :user2_left_at, :utc_datetime_usec

    belongs_to :user, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :user2, Tabletop.Accounts.User, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  def format_name(%__MODULE__{} = game) do
    @valid_formats[game.format]
  end

  def format_name_for(format) when is_atom(format) do
    @valid_formats[format]
  end

  def format_options do
    Enum.map(@valid_formats, fn {key, label} -> {label, key} end)
  end

  @doc false
  def changeset(game, attrs, user_scope) do
    game
    |> cast(attrs, [:title, :format, :hero, :decklist])
    |> validate_required([:title, :format])
    |> validate_inclusion(:format, Map.keys(@valid_formats))
    |> put_change(:user_id, user_scope.user.id)
  end
end
