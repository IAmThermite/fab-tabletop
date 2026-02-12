defmodule Tabletop.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @valid_formats %{
    classic_constructed: "Classic Constructed",
    silver_age: "Silver Age"
  }

  schema "games" do
    field :title, :string
    field :format, Ecto.Enum, values: Map.keys(@valid_formats), default: :classic_constructed

    belongs_to :user, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :user2, Tabletop.Accounts.User, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  def format_name(%__MODULE__{} = game) do
    @valid_formats[game.format]
  end

  @doc false
  def changeset(game, attrs, user_scope) do
    game
    |> cast(attrs, [:title, :format])
    |> validate_required([:title, :format])
    |> validate_inclusion(:format, Map.keys(@valid_formats))
    |> put_change(:user_id, user_scope.user.id)
  end
end
