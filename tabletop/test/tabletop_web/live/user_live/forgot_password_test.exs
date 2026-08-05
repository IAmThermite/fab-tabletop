defmodule TabletopWeb.UserLive.ForgotPasswordTest do
  use TabletopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletop.AccountsFixtures

  alias Tabletop.Accounts
  alias Tabletop.Accounts.UserToken
  alias Tabletop.Repo

  describe "Forgot password page" do
    test "renders the form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password")

      assert html =~ "Forgot your password?"
      assert html =~ "Send reset instructions"
    end

    test "is linked from the login page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        lv
        |> element("main a", "Forgot your password?")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/reset-password")

      assert html =~ "Send reset instructions"
    end
  end

  describe "sending reset instructions" do
    setup do
      %{user: user_fixture()}
    end

    test "sends a token to a registered user", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, conn} =
        lv
        |> form("#forgot_password_form", user: %{"email" => user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"

      assert Repo.get_by!(UserToken, user_id: user.id).context == "reset_password"
    end

    test "says the same thing for an unregistered email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password")

      {:ok, conn} =
        lv
        |> form("#forgot_password_form", user: %{"email" => "nobody@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert Repo.all(UserToken) == []
    end

    test "the emailed link resets the password", %{conn: conn, user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_reset_password_instructions(user, url)
        end)

      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert html =~ "Choose a new password"
    end
  end
end
