defmodule TabletopWeb.AdminLive.AnnouncementsTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tabletop.AnnouncementsFixtures
  import Tabletop.TournamentsFixtures, only: [admin_scope_fixture: 0]

  alias Tabletop.Announcements

  describe "access" do
    test "a signed-out visitor is redirected", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/tournaments"}}} = live(conn, ~p"/admin/announcements")
    end

    test "a signed-in non-admin is redirected", %{conn: conn} do
      # `admin_scope_fixture/0` sets :admin_ids, so create it first and log in
      # as somebody else to be sure the guard checks membership, not presence.
      admin_scope_fixture()
      player = Tabletop.AccountsFixtures.user_fixture()

      assert {:error, {:redirect, %{to: "/tournaments"}}} =
               conn |> log_in_user(player) |> live(~p"/admin/announcements")
    end

    test "an admin gets in", %{conn: conn} do
      admin = admin_scope_fixture()

      {:ok, _view, html} = conn |> log_in_user(admin.user) |> live(~p"/admin/announcements")

      assert html =~ "Site announcements"
    end
  end

  describe "publishing" do
    setup %{conn: conn} do
      admin = admin_scope_fixture()
      %{conn: log_in_user(conn, admin.user), admin: admin}
    end

    test "publishes an announcement and shows it on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/announcements")

      view
      |> form("#announcement-form", %{
        "announcement" => %{
          "message" => "Maintenance at 21:00 UTC",
          "level" => "warning",
          "duration_minutes" => "60",
          "dismissible" => "true"
        }
      })
      |> render_submit()

      # The "currently showing" card follows the broadcast rather than the
      # event reply — the same path another admin's publish takes — so it
      # lands on the next render.
      html = render(view)
      assert html =~ "Currently showing"
      assert html =~ "Maintenance at 21:00 UTC"

      announcement = Announcements.active()
      assert announcement.level == :warning
      assert announcement.dismissible
      assert DateTime.diff(announcement.ends_at, announcement.starts_at, :minute) == 60
    end

    test "keeps the level and duration selections while validating", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/announcements")

      html =
        view
        |> form("#announcement-form", %{
          "announcement" => %{
            "message" => "Half typed",
            "level" => "critical",
            "duration_minutes" => "240"
          }
        })
        |> render_change()

      # `duration_minutes` is a virtual *integer* against string option values,
      # so this is really checking that the select survives the round trip.
      assert html =~ ~s{<option selected="" value="critical">}
      assert html =~ ~s{<option selected="" value="240">}
    end

    test "shows validation errors instead of publishing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/announcements")

      html =
        view
        |> form("#announcement-form", %{"announcement" => %{"message" => ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute Announcements.active()
    end

    test "clears the active announcement", %{conn: conn} do
      announcement_fixture(message: "Maintenance at 21:00 UTC")

      {:ok, view, html} = live(conn, ~p"/admin/announcements")
      assert html =~ "Currently showing"

      view |> element("button", "Clear now") |> render_click()

      refute render(view) =~ "Currently showing"
      refute Announcements.active()
    end

    test "a cleared row stays in the log but visibly changes state", %{conn: conn} do
      a = announcement_fixture(message: "Maintenance at 21:00 UTC")

      {:ok, view, html} = live(conn, ~p"/admin/announcements")
      assert html =~ "Live"
      assert html =~ "No end time set"

      view
      |> element(~s{button[phx-click="clear"][phx-value-id="#{a.id}"].btn-xs})
      |> render_click()

      html = render(view)

      # Clearing is not deleting — the record survives as a log entry, so the
      # row has to say so itself rather than just losing its badge.
      assert html =~ "Maintenance at 21:00 UTC"
      assert html =~ "Ended"
      refute html =~ "No end time set"
      refute html =~ ~s{phx-click="clear"}
    end

    test "a row goes to Ended when its window closes on its own", %{conn: conn} do
      # A short window, so the expiry timer the hook arms is the only thing
      # that can move the row — no reload, no broadcast.
      announcement_fixture(
        message: "Brief notice",
        ends_at: DateTime.add(DateTime.utc_now(), 300, :millisecond)
      )

      {:ok, view, html} = live(conn, ~p"/admin/announcements")
      assert html =~ "Currently showing"
      assert html =~ "Live"

      # `render/1` runs after the queued expiry message, so no polling needed.
      Process.sleep(900)
      html = render(view)

      refute html =~ "Currently showing"
      assert html =~ "Brief notice"
      assert html =~ "Ended"
    end

    test "deletes an announcement from the log", %{conn: conn} do
      announcement = expired_announcement_fixture(message: "Old news")

      {:ok, view, html} = live(conn, ~p"/admin/announcements")
      assert html =~ "Old news"

      html =
        view
        |> element(~s{button[phx-click="delete"][phx-value-id="#{announcement.id}"]})
        |> render_click()

      refute html =~ "Old news"
      assert Announcements.list_announcements() == []
    end

    test "the admin's own page picks up another admin's publish", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, ~p"/admin/announcements")

      {:ok, _} = Announcements.create_announcement(admin, %{"message" => "From elsewhere"})

      assert render(view) =~ "From elsewhere"
    end
  end
end
