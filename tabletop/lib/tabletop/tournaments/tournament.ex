defmodule Tabletop.Tournaments.Tournament do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @formats %{
    classic_constructed: "Classic Constructed",
    silver_age: "Silver Age",
    living_legend: "Living Legend"
  }

  @statuses [:draft, :registration, :swiss, :cut, :finished, :cancelled]
  @cut_sizes [0, 4, 8, 16]

  # Default round durations in seconds per format.
  @default_durations %{
    classic_constructed: 55 * 60,
    silver_age: 35 * 60,
    living_legend: 55 * 60
  }

  schema "tournaments" do
    field :name, :string
    field :description, :string
    field :format, Ecto.Enum, values: Map.keys(@formats), default: :classic_constructed
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :max_players, :integer, default: 32
    field :swiss_rounds, :integer, default: 4
    field :top_cut_size, :integer, default: 8
    field :round_duration_seconds, :integer, default: 3300
    field :starts_at, :utc_datetime_usec

    belongs_to :created_by, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :winner, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :current_round, Tabletop.Tournaments.TournamentRound, type: Ecto.UUID

    has_many :registrations, Tabletop.Tournaments.TournamentRegistration
    has_many :rounds, Tabletop.Tournaments.TournamentRound
    has_many :matches, Tabletop.Tournaments.TournamentMatch

    timestamps(type: :utc_datetime)
  end

  def formats, do: @formats
  def format_options, do: Enum.map(@formats, fn {k, label} -> {label, k} end)
  def format_name(%__MODULE__{format: f}), do: @formats[f]
  def format_name_for(f) when is_atom(f), do: @formats[f]

  def cut_size_options, do: [{"No top cut", 0}, {"Top 4", 4}, {"Top 8", 8}, {"Top 16", 16}]

  def default_duration_for(format) when is_atom(format) do
    Map.get(@default_durations, format, 55 * 60)
  end

  @doc false
  def changeset(tournament, attrs, scope) do
    tournament
    |> cast(attrs, [
      :name,
      :description,
      :format,
      :max_players,
      :swiss_rounds,
      :top_cut_size,
      :round_duration_seconds,
      :starts_at
    ])
    |> validate_required([:name, :format, :max_players, :swiss_rounds])
    |> validate_inclusion(:format, Map.keys(@formats))
    |> validate_inclusion(:top_cut_size, @cut_sizes)
    |> validate_number(:max_players, greater_than_or_equal_to: 2)
    |> validate_number(:swiss_rounds, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
    |> validate_number(:round_duration_seconds, greater_than_or_equal_to: 60)
    |> maybe_put_creator(scope)
  end

  def status_changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [:status, :current_round_id, :winner_id])
    |> validate_inclusion(:status, @statuses)
  end

  defp maybe_put_creator(changeset, %{user: %{id: id}}) do
    if get_field(changeset, :created_by_id), do: changeset, else: put_change(changeset, :created_by_id, id)
  end

  defp maybe_put_creator(changeset, _), do: changeset
end
