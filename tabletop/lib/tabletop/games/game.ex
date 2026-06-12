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
    field :joining_expires_at, :utc_datetime_usec
    field :private, :boolean, default: false

    belongs_to :user, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :user2, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :joining_user, Tabletop.Accounts.User, type: Ecto.UUID
    has_one :game_state, Tabletop.Games.GameState

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
    |> cast(attrs, [:title, :format, :hero, :decklist, :private])
    |> validate_required([:title, :format])
    |> validate_inclusion(:format, Map.keys(@valid_formats))
    |> put_change(:user_id, user_scope.user.id)
    |> put_active_game_constraints()
  end

  @doc """
  Builds a game row for a tournament match (both players known up front).
  Declares the same one-active-game-per-user constraints as `changeset/3` so a
  collision surfaces as a changeset error rather than a raw `Ecto.ConstraintError`.
  """
  def match_changeset(game, attrs) do
    game
    |> cast(attrs, [:title, :format, :status, :user_id, :user2_id])
    |> validate_required([:title, :format, :user_id, :user2_id])
    |> validate_inclusion(:format, Map.keys(@valid_formats))
    |> put_active_game_constraints()
  end

  # Both partial unique indexes from the `one_active_game_per_user` migration:
  # a user may be user1 of at most one live game, and user2 of at most one.
  defp put_active_game_constraints(changeset) do
    changeset
    |> unique_constraint(:user_id,
      name: :games_one_active_per_user1,
      message: "you are already in a game"
    )
    |> unique_constraint(:user2_id,
      name: :games_one_active_per_user2,
      message: "your opponent is already in a game"
    )
  end
end
