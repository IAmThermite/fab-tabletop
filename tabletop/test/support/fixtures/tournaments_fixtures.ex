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

  @doc """
  Drives a 2-player, single-Swiss-round, no-cut tournament to completion and
  returns `{tournament, champion_user}`. Requires an admin scope (the test
  config sets `check_in_min_seconds` to 0 so it can start immediately).
  """
  def finished_tournament_fixture(%Scope{} = admin) do
    t = tournament_fixture(scope: admin, params: %{"swiss_rounds" => 1, "top_cut_size" => 0})
    {:ok, t} = Tournaments.open_registration(admin, t)

    players =
      for _ <- 1..2 do
        s = Scope.for_user(user_fixture())

        {:ok, _} =
          Tournaments.register(s, t.id, %{
            "hero" => "arakni-huntsman",
            "decklist_url" => valid_fabrary_url()
          })

        s
      end

    {:ok, t} = Tournaments.open_check_in(admin, t)
    for s <- players, do: {:ok, _} = Tournaments.check_in(s, t.id)
    {:ok, t} = Tournaments.start_tournament(admin, t)

    [match] = Tournaments.list_matches_for_round(t.current_round_id)
    {:ok, _} = Tournaments.override_match(admin, match.id, "p1_win")

    t = Tournaments.get_tournament!(t.id)
    {:ok, t} = Tournaments.generate_top_cut(admin, t)

    champion = Enum.find(players, &(&1.user.id == t.winner_id)).user
    {t, champion}
  end
end
