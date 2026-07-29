defmodule TabletopWeb.TournamentLive.AdminTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tabletop.Accounts.Scope
  alias Tabletop.Tournaments
  alias Tabletop.TournamentsFixtures

  setup %{conn: conn} do
    user = Tabletop.AccountsFixtures.user_fixture()
    Application.put_env(:tabletop, :admin_emails, [user.email])
    %{conn: log_in_user(conn, user), scope: Scope.for_user(user)}
  end

  test "renders the phase stepper, controls and danger zone for a draft", %{
    conn: conn,
    scope: scope
  } do
    t = TournamentsFixtures.tournament_fixture(scope: scope)
    {:ok, _view, html} = live(conn, ~p"/tournaments/#{t}/admin")

    # Lifecycle stepper labels (default fixture has no top cut, so it's omitted).
    assert html =~ ~s(class="steps)
    assert html =~ "Draft"
    assert html =~ "Check-in"
    assert html =~ "Swiss"
    assert html =~ "Finished"
    refute html =~ "Top cut"

    # Phase controls + danger zone still present.
    assert html =~ "Open registration"
    assert html =~ "Danger zone"
  end

  test "includes a Top cut step when the tournament has a cut", %{conn: conn, scope: scope} do
    t = TournamentsFixtures.tournament_fixture(scope: scope, params: %{"top_cut_size" => 8})
    {:ok, _view, html} = live(conn, ~p"/tournaments/#{t}/admin")

    assert html =~ "Top cut"
  end

  test "a cancelled tournament shows the cancelled state and hides the danger zone", %{
    conn: conn,
    scope: scope
  } do
    t = TournamentsFixtures.tournament_fixture(scope: scope)
    {:ok, _} = Tournaments.cancel_tournament(scope, t)

    {:ok, _view, html} = live(conn, ~p"/tournaments/#{t}/admin")

    assert html =~ "This tournament was cancelled."
    refute html =~ "Danger zone"
  end

  test "a finished tournament shows the champion by name, not a raw id", %{
    conn: conn,
    scope: scope
  } do
    {t, champion} = TournamentsFixtures.finished_tournament_fixture(scope)

    {:ok, _view, html} = live(conn, ~p"/tournaments/#{t}/admin")

    assert html =~ "Champion:"
    assert html =~ champion.name
    refute html =~ "Winner ID:"
  end
end
