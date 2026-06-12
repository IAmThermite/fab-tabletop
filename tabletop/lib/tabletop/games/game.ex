defmodule Tabletop.Games.Game do
  use Ecto.Schema
  import Ecto.Changeset

  alias Tabletop.Heroes

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @valid_formats %{
    classic_constructed: "Classic Constructed",
    silver_age: "Silver Age",
    living_legend: "Living Legend",
    blitz: "Blitz"
  }

  schema "games" do
    field :title, :string
    field :format, Ecto.Enum, values: Map.keys(@valid_formats), default: :classic_constructed

    field :language, Ecto.Enum,
      values: Tabletop.Languages.keys(),
      default: Tabletop.Languages.default()

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
    |> cast(attrs, [:title, :format, :language, :hero, :decklist, :private])
    |> validate_required([:title, :format, :language])
    |> validate_inclusion(:format, Map.keys(@valid_formats))
    |> validate_inclusion(:language, Tabletop.Languages.keys())
    |> validate_hero_legal()
    |> put_change(:user_id, user_scope.user.id)
    |> unique_constraint(:user_id,
      name: :games_one_active_per_user1,
      message: "you are already in a game"
    )
  end

  # Hero is optional — a blank hero means "hidden" (not shown). When a hero IS
  # chosen it must be a recognised hero and legal in the selected format.
  # Tournament games will enforce a hero separately (upcoming work). Legacy
  # free-text heroes on already-saved games predate this and aren't re-validated.
  defp validate_hero_legal(changeset) do
    hero = get_field(changeset, :hero)
    format = get_field(changeset, :format)

    cond do
      blank?(hero) -> changeset
      is_nil(format) -> changeset
      Heroes.legal?(hero, format) -> changeset
      Heroes.known?(hero) -> add_error(changeset, :hero, "is not legal in this format")
      true -> add_error(changeset, :hero, "is not a recognized hero")
    end
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
