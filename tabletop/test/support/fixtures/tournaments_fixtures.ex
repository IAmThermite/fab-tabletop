defmodule Tabletop.TournamentsFixtures do
  @moduledoc """
  Fixtures for the Tournaments context.
  """

  import Tabletop.AccountsFixtures
  alias Tabletop.Accounts.Scope
  alias Tabletop.Tournaments

  def admin_scope_fixture do
    user = user_fixture()
    Application.put_env(:tabletop, :admin_emails, [user.email])
    Scope.for_user(user)
  end

  def tournament_fixture(attrs \\ []) do
    attrs = Enum.into(attrs, %{})
    scope = attrs[:scope] || admin_scope_fixture()

    params =
      %{
        "name" => "Tournament #{System.unique_integer([:positive])}",
        "format" => "classic_constructed",
        "max_players" => 32,
        "swiss_rounds" => 2,
        "top_cut_size" => 0,
        "round_duration_seconds" => 3300
      }
      |> Map.merge(Map.get(attrs, :params, %{}))

    {:ok, t} = Tournaments.create_tournament(scope, params)
    t
  end

  def valid_fabrary_url, do: "https://fabrary.net/decks/abc123"
end
