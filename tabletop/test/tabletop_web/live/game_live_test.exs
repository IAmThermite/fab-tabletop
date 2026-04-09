defmodule TabletopWeb.GameLiveTest do
  use TabletopWeb.ConnCase

  import Phoenix.LiveViewTest
  import Tabletop.GamesFixtures
  import Tabletop.AccountsFixtures

  @create_attrs %{title: "some title", format: :classic_constructed}
  @update_attrs %{title: "some updated title"}
  @invalid_attrs %{title: nil}

  setup :register_and_log_in_user

  defp create_game(%{scope: scope}) do
    game = game_fixture(scope)

    %{game: game}
  end

  describe "Index" do
    test "shows three-column layout", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Games to join"
      assert html =~ "Create Game"
      assert html =~ "News"
    end

    test "creates new game inline", %{conn: conn} do
      {:ok, live_view, _html} = live(conn, ~p"/")

      assert live_view
             |> form("#create-game-form", game: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _show_live, html} =
               live_view
               |> form("#create-game-form", game: @create_attrs)
               |> render_submit()
               |> follow_redirect(conn)

      assert html =~ "Game created successfully"
    end

    test "shows joinable games from other users", %{conn: conn} do
      other_scope = user_scope_fixture()
      game_fixture(other_scope, %{title: "Joinable Game"})

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Joinable Game"
    end

    test "does not show own games in games to join", %{conn: conn, scope: scope} do
      game_fixture(scope, %{title: "My Own Game"})

      {:ok, live_view, _html} = live(conn, ~p"/")

      refute has_element?(live_view, ".space-y-3", "My Own Game")
    end

    test "joins a game", %{conn: conn} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Join Me"})

      {:ok, live_view, _html} = live(conn, ~p"/")

      assert {:ok, _pre_join_live, _html} =
               live_view
               |> element("button", "JOIN")
               |> render_click()
               |> follow_redirect(conn, ~p"/games/#{game}/pre-join")
    end
  end

  describe "Show" do
    setup [:create_game]

    test "displays game", %{conn: conn, game: game} do
      {:ok, _show_live, html} = live(conn, ~p"/games/#{game}")

      assert html =~ game.title
      assert html =~ "game-video"
      assert html =~ "remote-canvas"
    end

    test "has leave button that navigates to games list", %{conn: conn, game: game} do
      {:ok, show_live, _html} = live(conn, ~p"/games/#{game}")

      assert has_element?(show_live, "button[title='Leave Game']")
    end
  end

  describe "Edit" do
    setup [:create_game]

    test "updates game", %{conn: conn, game: game} do
      {:ok, form_live, _html} = live(conn, ~p"/games/#{game}/edit")

      assert render(form_live) =~ "Edit Game"

      assert form_live
             |> form("#game-form", game: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, _show_live, html} =
               form_live
               |> form("#game-form", game: @update_attrs)
               |> render_submit()
               |> follow_redirect(conn)

      assert html =~ "Game updated successfully"
      assert html =~ "some updated title"
    end
  end
end
