defmodule TabletopWeb.TournamentLive.FormTest do
  use TabletopWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = Tabletop.AccountsFixtures.user_fixture()
    Application.put_env(:tabletop, :admin_emails, [user.email])
    %{conn: log_in_user(conn, user)}
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
        "max_players" => "8",
        "swiss_rounds" => "3",
        "top_cut_size" => "0",
        "round_duration_minutes" => "40"
      }
    )
    |> render_submit()

    t = Enum.find(Tabletop.Tournaments.list_tournaments(), &(&1.name == "Minutes Test"))
    assert t.round_duration_seconds == 40 * 60
  end
end
