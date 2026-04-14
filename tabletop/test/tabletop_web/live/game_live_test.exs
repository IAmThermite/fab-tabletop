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

  describe "Index (unauthenticated)" do
    test "shows games list without join buttons", %{conn: _conn} do
      fresh_conn = Phoenix.ConnTest.build_conn()
      other_scope = user_scope_fixture()
      game_fixture(other_scope, %{title: "Visible Game"})

      {:ok, live_view, html} = live(fresh_conn, ~p"/")

      assert html =~ "Games to join"
      assert html =~ "Visible Game"
      refute has_element?(live_view, "button", "JOIN")
    end

    test "shows login prompt instead of create form", %{conn: _conn} do
      fresh_conn = Phoenix.ConnTest.build_conn()
      {:ok, _live_view, html} = live(fresh_conn, ~p"/")

      assert html =~ "Log in"
      refute html =~ ~s(id="create-game-form")
    end
  end

  describe "Index (unconfirmed user)" do
    setup :register_and_log_in_unconfirmed_user

    test "shows games list with join buttons", %{conn: conn} do
      other_scope = user_scope_fixture()
      game_fixture(other_scope, %{title: "Joinable Game"})

      {:ok, live_view, _html} = live(conn, ~p"/")

      assert has_element?(live_view, "button", "JOIN")
    end

    test "blocks join with flash when email not confirmed", %{conn: conn} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Blocked Join"})

      {:ok, live_view, _html} = live(conn, ~p"/")

      result =
        live_view
        |> element("button[phx-value-id='#{game.id}']", "JOIN")
        |> render_click()

      assert result =~ "Please confirm your email address before joining a game."
    end

    test "blocks create with flash when email not confirmed", %{conn: conn} do
      {:ok, live_view, _html} = live(conn, ~p"/")

      result =
        live_view
        |> form("#create-game-form", game: @create_attrs)
        |> render_submit()

      assert result =~ "Please confirm your email address before creating a game."
    end

    test "shows email confirmation banner with resend button", %{conn: conn} do
      {:ok, _live_view, html} = live(conn, ~p"/")

      assert html =~ "Email Confirmation Required"
      assert html =~ "Resend Confirmation Email"
    end

    test "resend confirmation button sends email", %{conn: conn} do
      {:ok, live_view, _html} = live(conn, ~p"/")

      result =
        live_view
        |> element("button", "Resend Confirmation Email")
        |> render_click()

      assert result =~ "Confirmation email sent"
    end
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

      assert {:error, {:live_redirect, %{to: to}}} =
               live_view
               |> element("button[phx-value-id='#{game.id}']", "JOIN")
               |> render_click()

      assert to == ~p"/games/#{game}/pre-join"
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

  describe "Pre-join (unconfirmed user)" do
    test "redirects to index with flash when email not confirmed", %{conn: _conn} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> log_in_user(unconfirmed_user_fixture())

      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Guarded Game"})

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, ~p"/games/#{game}/pre-join")

      assert message =~ "Please confirm your email address"
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
