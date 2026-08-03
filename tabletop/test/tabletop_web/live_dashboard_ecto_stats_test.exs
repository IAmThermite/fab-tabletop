defmodule TabletopWeb.LiveDashboardEctoStatsTest do
  @moduledoc """
  Guards the Ecto Stats wiring: the optional `:ecto_psql_extras` dep being
  present, and `Tabletop.Repo` being passed to `live_dashboard/2`. Drop either
  and the page silently degrades to install instructions rather than failing
  loudly, so it is worth asserting on.
  """
  use TabletopWeb.ConnCase, async: false

  alias Tabletop.AccountsFixtures

  setup do
    previous = Application.get_env(:tabletop, :live_dashboard_user_ids, [])
    on_exit(fn -> Application.put_env(:tabletop, :live_dashboard_user_ids, previous) end)

    user = AccountsFixtures.user_fixture()
    Application.put_env(:tabletop, :live_dashboard_user_ids, [user.id])

    %{user: user}
  end

  test "the repo is wired into the Ecto Stats page", %{conn: conn, user: user} do
    html =
      conn
      |> log_in_user(user)
      |> get(~p"/dev/dashboard/ecto_stats")
      |> html_response(200)

    assert html =~ "Tabletop.Repo"
    refute html =~ "should be installed"
  end

  test "the extras queries are available for the repo" do
    queries = EctoPSQLExtras.queries({Tabletop.Repo, node()})

    # A representative spread of the always-available queries — these need no
    # Postgres extension, unlike :calls / :outliers, which `queries/1` omits
    # unless pg_stat_statements is installed.
    for key <- [:cache_hit, :index_usage, :table_size, :seq_scans, :vacuum_stats] do
      assert Map.has_key?(queries, key), "expected #{key} to be an available Ecto Stats query"
    end
  end

  test "a query returns real rows from the database" do
    %{columns: columns, rows: rows} =
      EctoPSQLExtras.query(:cache_hit, Tabletop.Repo, format: :raw)

    assert columns == ["name", "ratio"]
    assert length(rows) > 0
  end
end
