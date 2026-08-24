defmodule TabletopWeb.GameAlertTrayTest do
  @moduledoc """
  The game layout is a fullscreen video grid, so every alert it can raise is
  collapsed behind one top-bar button rather than floated over the board. These
  cover the server-rendered half of that — the client half (counting, opening,
  the badge) lives in the `.AlertTray` colocated hook.

  `/camera-setup` stands in for the game view where a full game isn't needed: it
  uses `Layouts.game` and needs no game, opponent or WebRTC fixture.
  """
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tabletop.AnnouncementsFixtures

  defp tray(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#game-alert-tray")
  defp panel(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("#game-alert-panel")
  defp hidden?(nodes), do: LazyHTML.attribute(nodes, "hidden") != []
  defp present?(nodes), do: Enum.count(nodes) > 0

  test "ships collapsed, with the toggle hidden when there is nothing to show", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/camera-setup")

    # An empty tray must add *nothing* to the bar — not even its own button.
    assert tray(html) |> LazyHTML.query("[data-toggle]") |> hidden?()
    assert panel(html) |> hidden?()
  end

  test "sits inline in the top bar, not over the board", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/camera-setup")
    [class] = tray(html) |> LazyHTML.attribute("class")

    # A fixed corner is what put this over the opponent's life total
    # (`absolute bottom-2 right-2` in `game_tiles/1`). The tray is a sibling of
    # the other top-bar controls now and must stay one.
    refute class =~ "fixed"
    refute class =~ "bottom-"

    # The panel drops beneath the bell instead of reflowing the bar.
    [panel_class] = panel(html) |> LazyHTML.attribute("class")
    assert panel_class =~ "absolute"
    assert panel_class =~ "top-full"
  end

  test "collects the flash and the announcement into the panel", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, view, _html} = live(conn, ~p"/camera-setup")
    panel = panel(render(view))

    assert LazyHTML.to_html(panel) =~ "Maintenance at 21:00 UTC"
    assert present?(LazyHTML.query(panel, "[data-alert]"))
  end

  test "tray alerts do not erase themselves on a timer", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/camera-setup")

    # The five-second `JS.hide` the toast variant uses would make the unread
    # count lie: the badge would still say 1 for an alert that had erased
    # itself, and opening the tray would show an empty panel.
    refute tray(html) |> LazyHTML.to_html() =~ "fade-out"
  end

  test "connection loss stays outside the collapsed panel", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/camera-setup")
    tray = tray(html)
    panel = panel(html)

    # `#connection-status` in the game bar tracks the WebRTC peer, not the
    # LiveView socket, so these two are the only sign the socket itself dropped
    # — and a dropped socket is exactly when nothing can prompt a player to go
    # open a tray. They live in the tray but outside its collapsible part.
    assert present?(LazyHTML.query(tray, "#client-error"))
    assert present?(LazyHTML.query(tray, "#server-error"))
    refute present?(LazyHTML.query(panel, "#client-error"))
    refute present?(LazyHTML.query(panel, "#server-error"))

    # And they carry no `data-alert`, so they are chrome rather than tray
    # contents — a dropped socket must not silently bump the unread badge.
    assert Enum.count(LazyHTML.query(tray, "[data-alert]")) ==
             Enum.count(LazyHTML.query(panel, "[data-alert]"))
  end

  describe "placement across the game-layout pages" do
    # `Layouts.game` no longer renders the tray — there is no corner it can own,
    # so each page places it in its own top bar. That makes "this page forgot
    # it" a silent loss of every alert, which is what these pin down.
    setup :register_and_log_in_user

    test "the game view has it", %{conn: conn, scope: scope} do
      game = Tabletop.GamesFixtures.game_fixture(scope)

      {:ok, _view, html} = live(conn, ~p"/games/#{game}")

      assert present?(tray(html))
    end

    test "pre-join has it", %{conn: conn, scope: scope} do
      game = Tabletop.GamesFixtures.game_fixture(scope)

      {:ok, _view, html} = live(conn, ~p"/games/#{game}/pre-join")

      assert present?(tray(html))
    end

    test "camera setup has it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/camera-setup")

      assert present?(tray(html))
    end

    test "the phone camera has it", %{conn: conn, user: user} do
      token = TabletopWeb.CameraRelayToken.sign(TabletopWeb.Endpoint, user.id)

      {:ok, _view, html} = live(conn, ~p"/phone-camera/#{token}")

      assert present?(tray(html))
    end
  end

  test "the app layout keeps its ordinary toasts", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/")

    # The tray is a fix for the fullscreen video grid specifically; standard
    # pages have room and keep the banner + toast treatment.
    refute present?(tray(html))
    assert html =~ "system-announcement-banner-"
    assert html =~ ~s{id="flash-group"}
  end

  test "both layouts keep the notification sound hook", %{conn: conn} do
    # It used to be nested inside `flash_group/1`, which the game layout no
    # longer renders — dropping it would silently kill the audio cue in-game.
    {:ok, _view, game_html} = live(conn, ~p"/camera-setup")
    {:ok, _view, app_html} = live(conn, ~p"/")

    assert game_html =~ ~s{id="notification-sounds"}
    assert app_html =~ ~s{id="notification-sounds"}
  end
end
