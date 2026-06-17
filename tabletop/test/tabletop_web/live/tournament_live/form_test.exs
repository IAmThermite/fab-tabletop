defmodule TabletopWeb.TournamentLive.FormTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = Tabletop.AccountsFixtures.user_fixture()
    Application.put_env(:tabletop, :admin_emails, [user.email])
    %{conn: log_in_user(conn, user), user: user}
  end

  test "applying a preset fills the structure fields", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tournaments/new")

    html =
      view
      |> element("button[phx-value-preset=swiss_5_top8]")
      |> render_click()

    # 5-Round + Top 8 = 5 Swiss rounds, Top 8, 32 max players, suggested name.
    assert html =~ ~s(value="32")
    assert html =~ ~s(value="5-Round + Top 8")
    assert html =~ ~r/name="tournament\[swiss_rounds\]"[^>]*value="5"/
    # Round duration shows minutes (55), not seconds.
    assert html =~ ~r/name="tournament\[round_duration_minutes\]"[^>]*value="55"/
    # Top-8 option selected.
    assert html =~ ~s(<option selected="" value="8">)
    # The clicked preset button is highlighted.
    assert html =~ ~s(phx-value-preset="swiss_5_top8" class="btn btn-sm btn-primary")
  end

  test "a preset keeps a name the admin already typed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tournaments/new")

    render_change(view, "validate", %{
      "tournament" => %{"name" => "Friday Night", "format" => "classic_constructed"}
    })

    html =
      view
      |> element("button[phx-value-preset=armory_3]")
      |> render_click()

    assert html =~ ~s(value="Friday Night")
    refute html =~ ~s(value="Armory")
    assert html =~ ~r/name="tournament\[swiss_rounds\]"[^>]*value="3"/
  end

  test "reset clears the active preset and restores defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tournaments/new")

    view |> element("button[phx-value-preset=armory_3]") |> render_click()

    html = view |> element("button[phx-click=reset]") |> render_click()

    refute html =~ "btn btn-sm btn-primary"
    # Back to the schema default of 4 Swiss rounds.
    assert html =~ ~r/name="tournament\[swiss_rounds\]"[^>]*value="4"/
  end

  test "round duration is saved in seconds from the minutes input", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tournaments/new")

    view
    |> form("#tournament-form",
      tournament: %{
        "name" => "Minutes Test",
        "format" => "classic_constructed",
        "swiss_rounds" => "3",
        "top_cut_size" => "0",
        "round_duration_minutes" => "40"
      }
    )
    |> render_submit()

    t = Enum.find(Tabletop.Tournaments.list_tournaments(), &(&1.name == "Minutes Test"))
    assert t.round_duration_seconds == 40 * 60
  end

  test "start time uses a hidden UTC carrier and persists as UTC", %{conn: conn, user: user} do
    {:ok, _view, html} = live(conn, ~p"/tournaments/new")

    # The submitted field is a hidden UTC carrier; the visible datetime-local
    # picker is local-only (no name) and managed client-side by the hook.
    assert html =~ ~s(name="tournament[starts_at]")
    assert html =~ "data-utc-input"
    assert html =~ ~s(type="datetime-local")
    assert html =~ ~s(phx-update="ignore")

    # The hook submits a UTC ISO string, which must persist verbatim — no naive
    # re-interpretation of the admin's wall-clock as UTC.
    scope = Tabletop.Accounts.Scope.for_user(user)

    {:ok, t} =
      Tabletop.Tournaments.create_tournament(scope, %{
        "name" => "Timed Event",
        "format" => "classic_constructed",
        "max_players" => "8",
        "swiss_rounds" => "3",
        "top_cut_size" => "0",
        "round_duration_minutes" => "40",
        "starts_at" => "2026-06-20T19:00:00Z"
      })

    assert DateTime.compare(t.starts_at, ~U[2026-06-20 19:00:00Z]) == :eq
  end

  test "editing renders the stored start time as a UTC carrier value", %{
    conn: conn,
    user: user
  } do
    scope = Tabletop.Accounts.Scope.for_user(user)

    t =
      Tabletop.TournamentsFixtures.tournament_fixture(
        scope: scope,
        params: %{"starts_at" => "2026-06-20T19:00:00Z"}
      )

    {:ok, _view, html} = live(conn, ~p"/tournaments/#{t}/edit")

    assert html =~ ~s(value="2026-06-20T19:00:00Z")
  end
end
