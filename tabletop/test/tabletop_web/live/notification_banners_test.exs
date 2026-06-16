defmodule TabletopWeb.NotificationBannersTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tabletop.TournamentsFixtures

  alias Tabletop.Accounts.Scope
  alias Tabletop.Tournaments

  setup %{conn: conn} do
    admin = admin_scope_fixture()
    player = Tabletop.AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, player), admin: admin, player: player}
  end

  test "an open check-in shows a banner on the homepage and tournaments list", %{
    conn: conn,
    admin: admin,
    player: player
  } do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    # Need a second registrant so check-in can open (2-player minimum).
    other = Scope.for_user(Tabletop.AccountsFixtures.user_fixture())
    {:ok, _} = Tournaments.register(other, t.id, %{"decklist_url" => valid_fabrary_url()})

    {:ok, _} =
      Tournaments.register(Scope.for_user(player), t.id, %{"decklist_url" => valid_fabrary_url()})

    {:ok, _t} = Tournaments.open_check_in(admin, t)

    {:ok, _view, home_html} = live(conn, ~p"/")
    assert home_html =~ "Check-in is open for #{t.name}"

    {:ok, _view, list_html} = live(conn, ~p"/tournaments")
    assert list_html =~ "Check-in is open for #{t.name}"
  end

  test "a live notification raises a toast on the current page", %{
    conn: conn,
    admin: admin,
    player: player
  } do
    t = tournament_fixture(scope: admin)
    {:ok, t} = Tournaments.open_registration(admin, t)

    other = Scope.for_user(Tabletop.AccountsFixtures.user_fixture())
    {:ok, _} = Tournaments.register(other, t.id, %{"decklist_url" => valid_fabrary_url()})

    {:ok, _} =
      Tournaments.register(Scope.for_user(player), t.id, %{"decklist_url" => valid_fabrary_url()})

    # Player is sitting on the homepage when check-in opens.
    {:ok, view, _html} = live(conn, ~p"/")
    {:ok, _t} = Tournaments.open_check_in(admin, t)

    assert render(view) =~ "Check-in is open for #{t.name}"
  end
end
