defmodule TabletopWeb.TournamentLive.ShowTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tabletop.TournamentsFixtures

  setup :register_and_log_in_user

  test "shows a champion banner once the tournament is finished", %{conn: conn} do
    admin = TournamentsFixtures.admin_scope_fixture()
    {t, champion} = TournamentsFixtures.finished_tournament_fixture(admin)

    {:ok, _view, html} = live(conn, ~p"/tournaments/#{t}")

    # The "Champion" label is unique to the banner (the standings table doesn't
    # use it), so it confirms the banner — not just the standings row — rendered.
    assert html =~ "Champion"
    assert html =~ champion.name
  end
end
