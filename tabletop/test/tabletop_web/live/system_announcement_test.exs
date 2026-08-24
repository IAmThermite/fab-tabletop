defmodule TabletopWeb.SystemAnnouncementTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tabletop.AnnouncementsFixtures
  import Tabletop.TournamentsFixtures, only: [admin_scope_fixture: 0]

  alias Tabletop.Announcements

  describe "an already-active announcement" do
    test "shows to an anonymous visitor on the home page", %{conn: conn} do
      announcement_fixture(message: "Maintenance at 21:00 UTC")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Maintenance at 21:00 UTC"
      assert html =~ "system-announcement-banner-"
    end

    test "survives a reconnect, because it is read from the database on mount", %{conn: conn} do
      announcement_fixture(message: "Maintenance at 21:00 UTC")

      # The dead render (what a refresh lands on first) carries it too.
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Maintenance at 21:00 UTC"

      {:ok, _view, connected_html} = live(conn)
      assert connected_html =~ "Maintenance at 21:00 UTC"
    end

    test "is not shown before its window opens", %{conn: conn} do
      future_announcement_fixture(message: "Not yet")

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Not yet"
    end

    test "is not shown after its window closes", %{conn: conn} do
      expired_announcement_fixture(message: "Old news")

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Old news"
    end

    test "goes into the collapsed alert tray on the fullscreen game layout", %{conn: conn} do
      announcement_fixture(message: "Maintenance at 21:00 UTC")

      {:ok, _view, html} = live(conn, ~p"/camera-setup")

      assert html =~ "Maintenance at 21:00 UTC"
      assert html =~ "system-announcement-tray-"
      refute html =~ "system-announcement-banner-"

      # The panel ships closed, so the announcement is present in the DOM but
      # nothing is over the video until the player opens the tray.
      assert html =~ ~s{id="game-alert-panel"}
      assert [_, panel_attrs] = Regex.run(~r{<div id="game-alert-panel"([^>]*)>}, html)
      assert panel_attrs =~ "hidden"
    end

    test "nothing on the game layout is a floating toast", %{conn: conn} do
      announcement_fixture(message: "Maintenance at 21:00 UTC")

      {:ok, _view, html} = live(conn, ~p"/camera-setup")

      # `toast toast-top` is what parked a card over the video grid. The tray
      # replaced it; if it comes back, the obstruction comes back with it.
      refute html =~ "toast toast-top"
    end

    test "drops the dismiss button when it is not dismissible", %{conn: conn} do
      announcement_fixture(message: "You cannot close this", dismissible: false)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "You cannot close this"
      refute html =~ "data-dismiss"
    end

    test "is targetable by the pre-paint dismissal script", %{conn: conn} do
      # The server always renders the announcement — it cannot know what this
      # browser dismissed. Hiding an already-dismissed one before the dead
      # render paints is therefore a handshake between two places: the key the
      # component stamps on the element, and the selector the root layout's
      # <head> script builds from localStorage. Assert both ends so a rename on
      # one side can't silently reintroduce the flash.
      a = announcement_fixture(message: "Maintenance at 21:00 UTC")
      key = "#{a.id}-#{DateTime.to_unix(a.updated_at)}"

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "data-announcement-key=\"#{key}\""
      assert html =~ "localStorage.getItem(\"tabletop:dismissed-announcement\")"
      assert html =~ "[data-announcement-key=\"' + dismissedAnnouncement + '\"]"
    end

    test "carries the level through to the alert styling", %{conn: conn} do
      announcement_fixture(message: "Going down now", level: :critical)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "alert-error"
    end
  end

  describe "a live broadcast" do
    setup do
      %{admin: admin_scope_fixture()}
    end

    test "reaches a page the visitor is already sitting on", %{conn: conn, admin: admin} do
      {:ok, view, html} = live(conn, ~p"/")
      refute html =~ "Server restarting in 10 minutes"

      {:ok, _} =
        Announcements.create_announcement(admin, %{"message" => "Server restarting in 10 minutes"})

      assert render(view) =~ "Server restarting in 10 minutes"
    end

    test "reaches a player in the game layout", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, ~p"/camera-setup")

      {:ok, _} =
        Announcements.create_announcement(admin, %{"message" => "Server restarting in 10 minutes"})

      html = render(view)
      assert html =~ "Server restarting in 10 minutes"
      assert html =~ "system-announcement-tray-"
    end

    test "an expiring announcement leaves the screen without anyone writing", %{conn: conn} do
      # `ends_at` was previously only enforced on mount, so a "show this for an
      # hour" announcement stayed up forever for anyone already connected.
      announcement_fixture(
        message: "Back in a moment",
        ends_at: DateTime.add(DateTime.utc_now(), 300, :millisecond)
      )

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Back in a moment"

      Process.sleep(900)

      refute render(view) =~ "Back in a moment"
    end

    test "an expiry reveals an older announcement still inside its window", %{conn: conn} do
      now = DateTime.utc_now()

      announcement_fixture(
        message: "Long running notice",
        starts_at: DateTime.add(now, -60, :minute)
      )

      announcement_fixture(
        message: "Short notice",
        starts_at: DateTime.add(now, -1, :minute),
        ends_at: DateTime.add(now, 300, :millisecond)
      )

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Short notice"

      Process.sleep(900)
      html = render(view)

      refute html =~ "Short notice"
      assert html =~ "Long running notice"
    end

    test "clearing removes it from a page mid-session", %{conn: conn, admin: admin} do
      announcement = announcement_fixture(message: "Maintenance at 21:00 UTC")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Maintenance at 21:00 UTC"

      {:ok, _} = Announcements.clear_announcement(admin, announcement)

      refute render(view) =~ "Maintenance at 21:00 UTC"
    end

    test "gets a new DOM id so a dismissed announcement is replaced, not reused", %{
      conn: conn,
      admin: admin
    } do
      first = announcement_fixture(message: "First notice")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "system-announcement-banner-#{first.id}-"

      {:ok, second} = Announcements.create_announcement(admin, %{"message" => "Second notice"})

      html = render(view)
      assert html =~ "system-announcement-banner-#{second.id}-"
      refute html =~ "system-announcement-banner-#{first.id}-"
    end

    test "passes other messages through to the page's own handle_info", %{
      conn: conn,
      admin: admin
    } do
      # The hook attaches to every `handle_info` on the socket, so it has to
      # halt on its own message and let everything else fall through.
      # `GameLive.Index` has no catch-all clause, which makes both halves of
      # that observable here: the announcement must not crash it, and its own
      # tournament message must still arrive.
      {:ok, view, _html} = live(conn, ~p"/")

      {:ok, _} = Announcements.create_announcement(admin, %{"message" => "Heads up"})
      assert render(view) =~ "Heads up"

      t = Tabletop.TournamentsFixtures.tournament_fixture(scope: admin)
      {:ok, t} = Tabletop.Tournaments.open_registration(admin, t)

      html = render(view)
      assert html =~ t.name
      assert html =~ "Heads up"
    end
  end
end
