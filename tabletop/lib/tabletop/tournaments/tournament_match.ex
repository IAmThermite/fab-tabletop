defmodule Tabletop.Tournaments.TournamentMatch do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @reported_values ~w(p1_win p2_win draw)
  @confirmed_values ~w(p1_win p2_win draw double_loss bye)

  schema "tournament_matches" do
    field :table_number, :integer
    field :player1_reported, :string
    field :player2_reported, :string
    field :player1_games_won, :integer
    field :player2_games_won, :integer
    field :confirmed_result, :string
    field :confirmed_at, :utc_datetime_usec

    belongs_to :tournament, Tabletop.Tournaments.Tournament, type: Ecto.UUID
    belongs_to :round, Tabletop.Tournaments.TournamentRound, type: Ecto.UUID
    belongs_to :player1, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :player2, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :confirmed_by, Tabletop.Accounts.User, type: Ecto.UUID
    belongs_to :game, Tabletop.Games.Game, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  def reported_values, do: @reported_values
  def confirmed_values, do: @confirmed_values

  def new_changeset(match, attrs) do
    match
    |> cast(attrs, [:tournament_id, :round_id, :table_number, :player1_id, :player2_id])
    |> validate_required([:tournament_id, :round_id, :player1_id])
  end

  def report_changeset(match, attrs) do
    match
    |> cast(attrs, [:player1_reported, :player2_reported, :player1_games_won, :player2_games_won])
    |> validate_inclusion(:player1_reported, @reported_values)
    |> validate_inclusion(:player2_reported, @reported_values)
  end

  def confirm_changeset(match, attrs) do
    match
    |> cast(attrs, [:confirmed_result, :confirmed_at, :confirmed_by_id])
    |> validate_required([:confirmed_result])
    |> validate_inclusion(:confirmed_result, @confirmed_values)
  end

  def link_game_changeset(match, game_id) do
    change(match, game_id: game_id)
  end

  def bye?(%__MODULE__{player2_id: nil}), do: true
  def bye?(_), do: false

  @doc """
  True once a result has been entered for the match — either a player has
  reported, or an admin has confirmed/overridden. Used to treat the match's
  game as done (no longer joinable, hidden from "open live game" and the
  home-page banner).
  """
  def result_entered?(%__MODULE__{} = m) do
    not is_nil(m.player1_reported) or not is_nil(m.player2_reported) or
      not is_nil(m.confirmed_result)
  end

  def result_description("p1_win"), do: "Player 1 win"
  def result_description("p2_win"), do: "Player 2 win"
  def result_description("draw"), do: "Draw"
  def result_description("double_loss"), do: "Double loss"
  def result_description("bye"), do: "Bye"
  def result_description(nil), do: "Pending"
end
