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
      assert html =~ "Live activity"
    end

    test "shows hero and decklist on a joinable game row", %{conn: conn} do
      other_scope = user_scope_fixture()

      game_fixture(other_scope, %{
        title: "Hero Game",
        format: :living_legend,
        hero: "briar-warden-of-thorns",
        decklist: "https://fabrary.net/decks/abc123"
      })

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Briar, Warden of Thorns"
      assert html =~ "https://fabrary.net/decks/abc123"
    end

    test "shows a single empty state when no games are open", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "No open games right now"
      refute html =~ "No games available"
    end

    test "join private accepts a pasted game URL", %{conn: conn} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Private Game", private: true})

      {:ok, live_view, _html} = live(conn, ~p"/")

      live_view |> element("button", "Join private") |> render_click()

      assert {:error, {:live_redirect, %{to: to}}} =
               live_view
               |> form("#join-private-dialog form", code: "https://example.com/games/#{game.id}")
               |> render_submit()

      assert to == ~p"/games/#{game}/pre-join"
    end

    test "hero dropdown filters to heroes legal in the selected format", %{conn: conn} do
      {:ok, live_view, html} = live(conn, ~p"/")

      cc_hero = hd(Tabletop.Heroes.legal_for(:classic_constructed))
      blitz_only = Enum.find(Tabletop.Heroes.all(), &(&1.formats == [:blitz]))

      # Default format is Classic Constructed: a CC hero is listed, a
      # Blitz-only hero is not.
      assert html =~ cc_hero.name
      refute html =~ blitz_only.name

      # Switching the format to Blitz re-filters the options live.
      filtered =
        live_view
        |> form("#create-game-form", game: %{format: "blitz"})
        |> render_change()

      assert filtered =~ blitz_only.name
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

    # Skipped while the language selector is commented out of the create form
    # (GameLive.Index) — games now take the user's preferred / default language.
    # Re-enable together with the selector.
    @tag :skip
    test "creates a game with the selected language", %{conn: conn, scope: scope} do
      {:ok, live_view, _html} = live(conn, ~p"/")

      {:ok, _show, _html} =
        live_view
        |> form("#create-game-form", game: Map.put(@create_attrs, :language, :fra))
        |> render_submit()
        |> follow_redirect(conn)

      assert Tabletop.Games.get_current_game_for_user(scope).language == :fra
    end

    test "shows the game language on join rows", %{conn: conn} do
      other_scope = user_scope_fixture()
      game_fixture(other_scope, %{title: "DE Game", language: :deu})

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "DE Game"
      assert html =~ "· German"
    end

    # Skipped while the language-filter UI is commented out in the lobby
    # (GameLive.Index). Re-enable together with the filter controls.
    @tag :skip
    test "language filter narrows the joinable list", %{conn: conn} do
      en_scope = user_scope_fixture()
      game_fixture(en_scope, %{title: "English Game", language: :eng})
      fr_scope = user_scope_fixture()
      game_fixture(fr_scope, %{title: "French Game", language: :fra})

      {:ok, live_view, html} = live(conn, ~p"/")
      assert html =~ "English Game"
      assert html =~ "French Game"

      html =
        live_view
        |> element("button[phx-value-lang='fra']")
        |> render_click()

      assert html =~ "French Game"
      refute html =~ "English Game"
    end

    test "quick match is hidden until the user has a previous game", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")
      refute html =~ "Quick match"
    end

    test "quick match seeds the create form from the last game", %{conn: conn, scope: scope} do
      hero = hd(Tabletop.Heroes.legal_for(:classic_constructed))

      game =
        game_fixture(scope, %{
          title: "My Rematch Deck",
          format: :classic_constructed,
          hero: hero.slug,
          decklist: "https://fabrary.com/decks/abc"
        })

      {:ok, _} = Tabletop.Games.terminate_game(scope, game)

      {:ok, live_view, html} = live(conn, ~p"/")
      assert html =~ "Quick match"

      filled =
        live_view
        |> element("button", "Quick match")
        |> render_click()

      assert filled =~ "My Rematch Deck"
      assert filled =~ "https://fabrary.com/decks/abc"
      # The hero preview only renders for the selected hero, so its icon path
      # confirms the hero field was seeded too.
      assert filled =~ Tabletop.Heroes.icon_path(hero.slug)
    end
  end

  describe "Home tournaments column" do
    alias Tabletop.Repo
    alias Tabletop.Tournaments.Tournament

    test "lists upcoming and in-progress tournaments with links", %{conn: conn} do
      up = Repo.insert!(%Tournament{name: "Upcoming Open", status: :registration})
      live_t = Repo.insert!(%Tournament{name: "Live Swiss", status: :swiss})

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Upcoming Open"
      assert html =~ "Live Swiss"
      assert html =~ ~p"/tournaments/#{up}"
      assert html =~ ~p"/tournaments/#{live_t}"
      assert html =~ "View all"
    end

    test "excludes finished/draft tournaments and shows an empty state", %{conn: conn} do
      Repo.insert!(%Tournament{name: "Old Cup", status: :finished})
      Repo.insert!(%Tournament{name: "Secret Draft", status: :draft})

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "No tournaments scheduled"
      refute html =~ "Old Cup"
      refute html =~ "Secret Draft"
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

    test "keeps the client-managed opponent-volume control out of LiveView patches",
         %{conn: conn, game: game} do
      {:ok, _show_live, html} = live(conn, ~p"/games/#{game}")

      # The slider value + mute icon are driven client-side from localStorage,
      # so the control must opt out of LiveView DOM patching or a re-render
      # resets it.
      assert html =~ ~r/id="opponent-volume-control"[^>]*phx-update="ignore"/
    end
  end

  describe "Show (tournament match)" do
    alias Tabletop.Games
    alias Tabletop.Repo
    alias Tabletop.Tournaments
    alias Tabletop.TournamentsFixtures

    test "ending the game redirects participants to the tournament", %{conn: conn, scope: scope} do
      admin = TournamentsFixtures.admin_scope_fixture()
      t = TournamentsFixtures.tournament_fixture(scope: admin)
      {:ok, t} = Tournaments.open_registration(admin, t)

      # The logged-in user is one of the two paired players.
      {:ok, _} =
        Tournaments.register(scope, t.id, %{
          "decklist_url" => TournamentsFixtures.valid_fabrary_url()
        })

      opponent = user_scope_fixture()

      {:ok, _} =
        Tournaments.register(opponent, t.id, %{
          "decklist_url" => TournamentsFixtures.valid_fabrary_url()
        })

      {:ok, t} = Tournaments.open_check_in(admin, t)
      {:ok, _} = Tournaments.check_in(scope, t.id)
      {:ok, _} = Tournaments.check_in(opponent, t.id)
      {:ok, t} = Tournaments.start_tournament(admin, t)

      [match] = Tournaments.list_matches_for_round(t.current_round_id)
      game = Repo.get!(Games.Game, match.game_id)

      {:ok, show_live, _html} = live(conn, ~p"/games/#{game}")

      # The opponent leaving ends the game — the same `game_ended` broadcast the
      # disconnect grace timer fires. The surviving player goes to the tournament.
      {:ok, _} = Games.terminate_game(opponent, game)

      assert_redirect(show_live, ~p"/tournaments/#{t.id}", 2000)
    end
  end

  describe "Camera setup join" do
    test "joins a not-yet-participant user as user2 via save_and_join", %{conn: conn, user: user} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Join Via Setup"})

      {:ok, live_view, _html} = live(conn, ~p"/camera-setup?game_id=#{game.id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(live_view, "save_and_join", %{})

      assert to == ~p"/games/#{game}"

      updated = Tabletop.Repo.reload!(game)
      assert updated.user2_id == user.id
      assert updated.status == :active
    end
  end

  describe "Show (non-participant recovery)" do
    test "routes a non-participant to pre-join instead of 404", %{conn: conn} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Someone Else's Game"})

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/games/#{game}")
      assert to == ~p"/games/#{game}/pre-join"
    end

    test "sends an unknown game to the lobby with a flash", %{conn: conn} do
      unknown = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/", flash: %{"error" => message}}}} =
               live(conn, ~p"/games/#{unknown}")

      assert message =~ "Game not found"
    end
  end

  describe "Pre-join skip gate" do
    test "disallows skipping for a not-yet-joined user", %{conn: conn} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Skip Gate Joiner"})

      {:ok, _live, html} = live(conn, ~p"/games/#{game}/pre-join")
      assert html =~ ~s(data-skip-allowed="false")
    end

    test "allows skipping for a participant (the creator)", %{conn: conn, scope: scope} do
      game = game_fixture(scope, %{title: "Skip Gate Creator"})

      {:ok, _live, html} = live(conn, ~p"/games/#{game}/pre-join")
      assert html =~ ~s(data-skip-allowed="true")
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
