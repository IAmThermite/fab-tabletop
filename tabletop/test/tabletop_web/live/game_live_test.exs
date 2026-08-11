defmodule TabletopWeb.GameLiveTest do
  use TabletopWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tabletop.GamesFixtures
  import Tabletop.AccountsFixtures

  @create_attrs %{
    title: "some title",
    format: :classic_constructed,
    hero: hd(Tabletop.Heroes.legal_for(:classic_constructed)).slug
  }
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

    test "shows recent tournament winners once a tournament has finished", %{conn: conn} do
      admin = Tabletop.TournamentsFixtures.admin_scope_fixture()
      {tournament, champion} = Tabletop.TournamentsFixtures.finished_tournament_fixture(admin)

      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "Recent winners"
      assert html =~ champion.name
      assert html =~ tournament.name
      # The champion's hero and a link to their deck.
      assert html =~ "Arakni, Huntsman"
      assert html =~ Tabletop.TournamentsFixtures.valid_fabrary_url()
    end

    test "hides the recent winners card when no tournament has finished", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/")

      refute html =~ "Recent winners"
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

    test "hides the hero and decklist on a competitive game row", %{conn: conn} do
      other_scope = user_scope_fixture()

      game_fixture(other_scope, %{
        title: "Competitive Game",
        format: :living_legend,
        hero: "briar-warden-of-thorns",
        decklist: "https://fabrary.net/decks/secret",
        competitive: true
      })

      {:ok, live, html} = live(conn, ~p"/")

      # The game is still listed, but on its row the hero name and decklist are
      # hidden and a "Competitive" marker is shown instead. The hero name is only
      # refuted within the joinable-games list — competitive games now feed the
      # separate "Popular heroes" panel, where the name legitimately appears.
      joinable = live |> element("#joinable-games") |> render()

      assert joinable =~ "Competitive Game"
      assert joinable =~ "Competitive"
      refute joinable =~ "Briar, Warden of Thorns"
      refute html =~ "https://fabrary.net/decks/secret"
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

      # The dialog is teleported to <body> by `<.portal>`, and LiveViewTest can't
      # select inside a portal — render the portal to check it opened, then send
      # the submit to the view itself.
      assert live_view |> element("#join-private-portal") |> render() =~ "Join private game"

      assert {:error, {:live_redirect, %{to: to}}} =
               render_submit(live_view, "join_private", %{
                 "code" => "https://example.com/games/#{game.id}"
               })

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

    test "quick match re-seeds the create form from the last created game", %{
      conn: conn,
      scope: scope
    } do
      last =
        game_fixture(scope, %{
          title: "Rematch Me",
          format: :blitz,
          language: :deu,
          hero: "aurora",
          decklist: "https://fabrary.net/decks/rematch",
          private: true,
          competitive: true
        })

      # The seeded form is only submittable once the previous game is over —
      # a user may only be in one live game at a time.
      Tabletop.Games.terminate_game(scope, last)

      {:ok, live_view, _html} = live(conn, ~p"/")

      live_view |> element("button", "Quick match") |> render_click()

      # Submit with no overrides: the params come straight from the seeded DOM,
      # so the created game proves what the button actually filled in.
      {:ok, _show, _html} =
        live_view
        |> form("#create-game-form")
        |> render_submit()
        |> follow_redirect(conn)

      created = Tabletop.Games.get_current_game_for_user(scope)

      assert created.id != last.id
      assert created.title == "Rematch Me"
      assert created.format == :blitz
      assert created.language == :deu
      assert created.hero == "aurora"
      assert created.decklist == "https://fabrary.net/decks/rematch"
      assert created.private
      assert created.competitive
    end

    test "quick match skips tournament matches and reuses the last real game", %{
      conn: conn,
      scope: scope
    } do
      own =
        game_fixture(scope, %{
          title: "My Deck Night",
          format: :blitz,
          hero: "aurora",
          decklist: "https://fabrary.net/decks/mine"
        })

      Tabletop.Games.terminate_game(scope, own)

      # A tournament match is an ordinary Game row with this user as `user_id`,
      # but it carries no hero or decklist — seeding from it blanked the form.
      opponent = user_scope_fixture()

      {:ok, match_game} =
        %Tabletop.Games.Game{}
        |> Tabletop.Games.Game.match_changeset(%{
          title: "Summer Cup — Swiss 1 · Table 3",
          format: :classic_constructed,
          status: :active,
          user_id: scope.user.id,
          user2_id: opponent.user.id
        })
        |> Tabletop.Repo.insert()

      Tabletop.Games.terminate_game(scope, match_game)

      # `inserted_at` is second-precision, so the fixtures above can tie. Push
      # the tournament row clear of the real game to pin down the ordering.
      Tabletop.Repo.update_all(
        from(g in Tabletop.Games.Game, where: g.id == ^match_game.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), 60)]
      )

      assert Tabletop.Games.get_last_created_game(scope).id == own.id

      {:ok, live_view, _html} = live(conn, ~p"/")

      live_view |> element("button", "Quick match") |> render_click()

      {:ok, _show, _html} =
        live_view
        |> form("#create-game-form")
        |> render_submit()
        |> follow_redirect(conn)

      created = Tabletop.Games.get_current_game_for_user(scope)

      assert created.title == "My Deck Night"
      assert created.hero == "aurora"
      assert created.decklist == "https://fabrary.net/decks/mine"
    end

    test "quick match button is hidden when the only game is a tournament match", %{
      conn: conn,
      scope: scope
    } do
      opponent = user_scope_fixture()

      {:ok, match_game} =
        %Tabletop.Games.Game{}
        |> Tabletop.Games.Game.match_changeset(%{
          title: "Summer Cup — Swiss 1 · Table 3",
          format: :classic_constructed,
          status: :active,
          user_id: scope.user.id,
          user2_id: opponent.user.id
        })
        |> Tabletop.Repo.insert()

      Tabletop.Games.terminate_game(scope, match_game)

      {:ok, live_view, _html} = live(conn, ~p"/")

      refute has_element?(live_view, "button", "Quick match")
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
      assert html =~ "remote-video"
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

    test "renders tiles in board coordinates inside a tile layer", %{conn: conn, game: game} do
      {:ok, show_live, _html} = live(conn, ~p"/games/#{game}")

      show_live
      |> element("input[phx-click='toggle_damage'][phx-value-type='physical']")
      |> render_click()

      # The tile appears via the game session's broadcast, so re-render once the
      # LiveView has handled it.
      html = render(show_live)

      # Tiles carry their board position on --tile-x/--tile-y rather than
      # left/top so a viewer whose board is drawn rotated 180° can mirror them
      # in CSS (the server never sees that client-side flip toggle). Baking
      # left/top in pins every tile to the side of the player who placed it.
      assert html =~ ~s(id="tile-layer-local")
      assert html =~ ~r/--tile-x: [\d.]+%; --tile-y: [\d.]+%/
      refute html =~ ~r/style="left: [\d.]+%/

      # The overlay the game hook sizes to the letterboxed remote canvas and
      # marks flipped; tiles are positioned against it, not against #game-area.
      assert has_element?(show_live, "#game-area > #tile-layer-remote")
    end
  end

  describe "Show (proxy tokens)" do
    alias Tabletop.Games
    alias Tabletop.Games.GameSession

    setup %{scope: scope} do
      game = game_fixture(scope)
      opponent = user_scope_fixture()
      {:ok, game} = Games.join_game(opponent, game, @create_attrs.hero)

      %{game: game, opponent: opponent}
    end

    defp open_proxy_picker(show_live) do
      show_live
      |> element("button[phx-value-name='create_proxy_token']")
      |> render_click()

      show_live
    end

    test "the picker targets the chosen side", %{conn: conn, game: game} do
      {:ok, show_live, _html} = live(conn, ~p"/games/#{game}")

      # Default target is the opponent — the common case, handing over a debuff.
      show_live
      |> open_proxy_picker()
      |> element("button[phx-click='add_proxy_token'][phx-value-type='Frostbite']")
      |> render_click()

      # Switching the target puts the next token on your own side instead.
      show_live
      |> element("button[phx-click='set_proxy_token_target'][phx-value-target='my']")
      |> render_click()

      show_live
      |> element("button[phx-click='add_proxy_token'][phx-value-type='Runechant']")
      |> render_click()

      assert %{
               user1: %{proxy_tokens: %{"Runechant" => 1}},
               user2: %{proxy_tokens: %{"Frostbite" => 1}}
             } = GameSession.get_state(game.id)
    end

    test "the panel lists both sides and clears from either", %{conn: conn, game: game} do
      {:ok, show_live, _html} = live(conn, ~p"/games/#{game}")

      show_live
      |> open_proxy_picker()
      |> element("input[phx-click='toggle_proxy_token'][phx-value-type='Mark']")
      |> render_click()

      show_live
      |> element("button[phx-click='set_proxy_token_target'][phx-value-target='my']")
      |> render_click()

      show_live
      |> element("button[phx-click='add_proxy_token'][phx-value-type='Runechant']")
      |> render_click()

      # Close the picker so the panel's controls are the only ones on the page.
      show_live |> element("button[phx-value-name='create_proxy_token']") |> render_click()

      html = render(show_live)
      assert html =~ "Proxy Tokens (2)"
      assert html =~ "Runechant"
      assert html =~ "Mark"

      # Expanded, the panel is a Yours/Opponent tab pair; each tab's controls
      # carry that side as their target.
      show_live |> element("button[phx-value-name='proxy_tokens_panel']") |> render_click()

      show_live
      |> element("#game-area button[phx-click='remove_proxy_token'][phx-value-target='my']")
      |> render_click()

      show_live
      |> element("button[phx-click='set_proxy_tokens_tab'][phx-value-target='opponent']")
      |> render_click()

      show_live
      |> element("#game-area button[phx-click='remove_proxy_token'][phx-value-target='opponent']")
      |> render_click()

      assert %{user1: %{proxy_tokens: %{}}, user2: %{proxy_tokens: %{}}} =
               GameSession.get_state(game.id)
    end

    test "a player sees and can dismiss what their opponent gave them",
         %{conn: conn, game: game, opponent: opponent} do
      # The opponent marks us from their own session.
      :ok = GameSession.ensure_started(game)

      :ok =
        GameSession.apply_action(
          game.id,
          opponent.user.id,
          {:add_proxy_token, game.user_id, "Mark"}
        )

      {:ok, show_live, html} = live(conn, ~p"/games/#{game}")

      assert html =~ "Proxy Tokens (1)"
      assert html =~ "Mark"

      show_live |> element("button[phx-value-name='proxy_tokens_panel']") |> render_click()

      show_live
      |> element("#game-area button[phx-click='remove_proxy_token'][phx-value-target='my']")
      |> render_click()

      assert %{user1: %{proxy_tokens: %{}}} = GameSession.get_state(game.id)
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
    test "routes a not-yet-participant user to pre-join (to pick a hero) via save_and_join",
         %{conn: conn} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Join Via Setup"})

      {:ok, live_view, _html} = live(conn, ~p"/camera-setup?game_id=#{game.id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               render_hook(live_view, "save_and_join", %{})

      # Non-participants must declare their hero in pre-join before joining, so
      # save_and_join sends them there rather than joining directly.
      assert to == ~p"/games/#{game}/pre-join"

      updated = Tabletop.Repo.reload!(game)
      assert is_nil(updated.user2_id)
      assert updated.status == :waiting
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

  describe "Pre-join (joiner hero selection)" do
    test "Continue is disabled until the joiner picks a hero, then joining records it",
         %{conn: conn, user: user} do
      other_scope = user_scope_fixture()
      game = game_fixture(other_scope, %{title: "Pick A Hero", format: :classic_constructed})
      cc_hero = hd(Tabletop.Heroes.legal_for(:classic_constructed))

      {:ok, live, html} = live(conn, ~p"/games/#{game}/pre-join")

      # The joiner sees a prominent hero picker and Continue starts disabled.
      assert html =~ "Choose your hero"
      assert has_element?(live, "#pre-join-hero-picker")
      assert live |> element("#pre-join-continue-btn") |> render() =~ "disabled"

      # Selecting a legal hero enables Continue.
      live
      |> element("#pre-join form")
      |> render_change(%{"hero" => cc_hero.slug})

      refute live |> element("#pre-join-continue-btn") |> render() =~ "disabled"

      # Continuing joins the game and records the joiner's hero.
      assert {:error, {:live_redirect, %{to: to}}} =
               live |> element("#pre-join-continue-btn") |> render_click()

      assert to == ~p"/games/#{game}"

      updated = Tabletop.Repo.reload!(game)
      assert updated.user2_id == user.id
      assert updated.user2_hero == cc_hero.slug
      assert updated.status == :active
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
