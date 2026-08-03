defmodule TabletopWeb.LiveDashboardAccessTest do
  @moduledoc """
  Covers the LiveDashboard authorization gate.

  These tests only mean anything outside `:dev_routes` — in development the
  dashboard is deliberately open and the router compiles a pipeline with no
  guard at all. The test environment does not set `:dev_routes`, so the routes
  exercised here are the ones production compiles.
  """
  use TabletopWeb.ConnCase, async: false

  alias Phoenix.LiveView
  alias Tabletop.Accounts.Scope
  alias Tabletop.AccountsFixtures
  alias TabletopWeb.UserAuth

  setup do
    previous = Application.get_env(:tabletop, :live_dashboard_user_ids, [])
    on_exit(fn -> Application.put_env(:tabletop, :live_dashboard_user_ids, previous) end)
    :ok
  end

  defp allow(user_ids) do
    Application.put_env(:tabletop, :live_dashboard_user_ids, user_ids)
  end

  describe "routes" do
    test "anonymous visitors are sent to log in", %{conn: conn} do
      conn = get(conn, ~p"/dev/dashboard/home")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "a logged-in user who is not listed is refused", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/dev/dashboard/home")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "do not have access"
    end

    test "the default empty list admits nobody", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      allow([])

      conn = conn |> log_in_user(user) |> get(~p"/dev/dashboard/home")

      assert redirected_to(conn) == ~p"/"
    end

    test "a listed user reaches the dashboard", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      allow([user.id])

      conn = conn |> log_in_user(user) |> get(~p"/dev/dashboard/home")

      assert html_response(conn, 200) =~ "LiveDashboard"
    end

    test "listing one user does not admit another", %{conn: conn} do
      listed = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      allow([listed.id])

      conn = conn |> log_in_user(other) |> get(~p"/dev/dashboard/home")

      assert redirected_to(conn) == ~p"/"
    end

    test "ids are matched case-insensitively", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      allow([String.upcase(user.id)])

      conn = conn |> log_in_user(user) |> get(~p"/dev/dashboard/home")

      assert html_response(conn, 200) =~ "LiveDashboard"
    end

    # The dashboard's stylesheet and script are plain controller routes that no
    # `on_mount` hook covers, which is why the pipeline carries the guard too.
    test "the dashboard assets are gated as well", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> log_in_user(user) |> get("/dev/dashboard/js-whatever")

      assert redirected_to(conn) == ~p"/"
    end
  end

  # The plug guards the HTTP request, but the LiveView's connected mount arrives
  # over the socket and never passes through the pipeline, so the hook is what
  # actually holds the door there. Exercised directly — a request-based test
  # would be halted by the plug before the hook ever ran.
  describe "on_mount :require_live_dashboard" do
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      token = Tabletop.Accounts.generate_user_session_token(user)

      session =
        conn
        |> Map.replace!(:secret_key_base, TabletopWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token)
        |> Plug.Conn.get_session()

      %{user: user, session: session}
    end

    test "continues for a listed user", %{user: user, session: session} do
      allow([user.id])

      assert {:cont, socket} =
               UserAuth.on_mount(:require_live_dashboard, %{}, session, %LiveView.Socket{})

      assert socket.assigns.current_scope.user.id == user.id
    end

    test "halts for an unlisted user", %{session: session} do
      socket = %LiveView.Socket{
        endpoint: TabletopWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, socket} =
               UserAuth.on_mount(:require_live_dashboard, %{}, session, socket)

      assert socket.redirected == {:redirect, %{to: ~p"/", status: 302}}
    end

    test "halts when there is no user at all" do
      socket = %LiveView.Socket{
        endpoint: TabletopWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _socket} = UserAuth.on_mount(:require_live_dashboard, %{}, %{}, socket)
    end
  end

  describe "Scope.live_dashboard?/1" do
    test "is false without a user" do
      refute Scope.live_dashboard?(nil)
      refute Scope.live_dashboard?(%Scope{user: nil})
    end

    test "ignores non-binary entries rather than crashing" do
      user = AccountsFixtures.user_fixture()
      allow([:not_a_string, user.id])

      assert Scope.live_dashboard?(Scope.for_user(user))
    end

    test "admin_ids does not grant dashboard access" do
      user = AccountsFixtures.user_fixture()
      Application.put_env(:tabletop, :admin_ids, [user.id])
      on_exit(fn -> Application.put_env(:tabletop, :admin_ids, []) end)
      allow([])

      assert Scope.admin?(Scope.for_user(user))
      refute Scope.live_dashboard?(Scope.for_user(user))
    end
  end
end
