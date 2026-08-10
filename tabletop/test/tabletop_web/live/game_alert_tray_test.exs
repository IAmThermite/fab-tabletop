defmodule TabletopWeb.GameAlertTrayTest do
  @moduledoc """
  The game layout is a fullscreen video grid, so every alert it can raise is
  collapsed behind one corner button rather than floated over the board. These
  cover the server-rendered half of that — the client half (counting, opening,
  the badge) lives in the `.AlertTray` colocated hook.

  `/camera-setup` stands in for the game view: it uses `Layouts.game` and needs
  no game, opponent or WebRTC fixture.
  """
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tabletop.AnnouncementsFixtures

  # Sliced between markers rather than matched with a nesting-blind regex: the
  # panel holds nested divs, and the colocated hook's <script> is extracted at
  # compile time so it never appears in the output to anchor against.
  defp between(html, from, to) do
    [_, rest] = String.split(html, from, parts: 2)
    [inner, _] = String.split(rest, to, parts: 2)
    inner
  end

  defp tray(html), do: between(html, ~s{id="game-alert-tray"}, ~s{id="notification-sounds"})
  defp panel(html), do: between(html, ~s{id="game-alert-panel"}, ~s{id="client-error"})

  test "ships collapsed, with the toggle hidden when there is nothing to show", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/camera-setup")

    tray = tray(html)

    # An empty tray must put *nothing* over the video — not even its own button.
    assert [_, button_attrs] = Regex.run(~r{<button data-toggle([^>]*)>}s, tray)
    assert button_attrs =~ "hidden"
    assert [_, panel_attrs] = Regex.run(~r{<div id="game-alert-panel"([^>]*)>}, tray)
    assert panel_attrs =~ "hidden"
  end

  test "collects the flash and the announcement into the panel", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, view, _html} = live(conn, ~p"/camera-setup")
    html = render(view)

    panel = panel(html)
    assert panel =~ "Maintenance at 21:00 UTC"
    assert panel =~ "data-alert"
  end

  test "tray alerts do not erase themselves on a timer", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/camera-setup")

    # The five-second `JS.hide` the toast variant uses would make the unread
    # count lie: the badge would still say 1 for an alert that had erased
    # itself, and opening the tray would show an empty panel.
    refute tray(html) =~ "fade-out"
  end

  test "connection loss stays outside the collapsed panel", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/camera-setup")
    tray = tray(html)

    # `#connection-status` in the game bar tracks the WebRTC peer, not the
    # LiveView socket, so these two are the only sign the socket itself dropped
    # — and a dropped socket is exactly when nothing can prompt a player to go
    # open a tray. They live in the tray but outside its collapsible part.
    assert tray =~ ~s{id="client-error"}
    assert tray =~ ~s{id="server-error"}
    assert tray =~ "phx-disconnected"
    refute panel(html) =~ "phx-disconnected"

    # And they carry no `data-alert`, so they are chrome rather than tray
    # contents — a dropped socket must not silently bump the unread badge.
    assert count(tray, "data-alert") == count(panel(html), "data-alert")
  end

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  test "the app layout keeps its ordinary toasts", %{conn: conn} do
    announcement_fixture(message: "Maintenance at 21:00 UTC")

    {:ok, _view, html} = live(conn, ~p"/")

    # The tray is a fix for the fullscreen video grid specifically; standard
    # pages have room and keep the banner + toast treatment.
    refute html =~ "game-alert-tray"
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
