defmodule TabletopWeb.UserLive.ResetPasswordTest do
  use TabletopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletop.AccountsFixtures

  alias Tabletop.Accounts
  alias Tabletop.Accounts.UserToken
  alias Tabletop.Repo

  setup do
    user = user_fixture()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_reset_password_instructions(user, url)
      end)

    %{token: token, user: user}
  end

  describe "Reset password page" do
    test "renders the form with a valid token", %{conn: conn, token: token} do
      {:ok, _lv, html} = live(conn, ~p"/users/reset-password/#{token}")

      assert html =~ "Choose a new password"
    end

    test "redirects with an invalid token", %{conn: conn} do
      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/oops")

      assert to.to == ~p"/users/reset-password"
      assert %{"error" => message} = to.flash
      assert message =~ "Reset password link is invalid or it has expired"
    end

    test "redirects with an expired token", %{conn: conn, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      {:error, {:redirect, to}} = live(conn, ~p"/users/reset-password/#{token}")

      assert to.to == ~p"/users/reset-password"
    end
  end

  describe "resetting the password" do
    test "resets the password and sends the user to log in", %{
      conn: conn,
      token: token,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      {:ok, conn} =
        lv
        |> form("#reset_password_form",
          user: %{
            "password" => "new valid password",
            "password_confirmation" => "new valid password"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password reset successfully"
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "burns the token, so the link can't be replayed", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      lv
      |> form("#reset_password_form",
        user: %{
          "password" => "new valid password",
          "password_confirmation" => "new valid password"
        }
      )
      |> render_submit()

      assert Repo.all(UserToken) == []
      assert {:error, {:redirect, _}} = live(conn, ~p"/users/reset-password/#{token}")
    end

    test "renders errors for a too-short password", %{conn: conn, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/users/reset-password/#{token}")

      result =
        lv
        |> element("#reset_password_form")
        |> render_change(
          user: %{"password" => "abc", "password_confirmation" => "does not match"}
        )

      assert result =~ "should be at least 4 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors on submit", %{conn: conn, token: token} do
      result =
        conn
        |> live(~p"/users/reset-password/#{token}")
        |> elem(1)
        |> form("#reset_password_form",
          user: %{"password" => "abc", "password_confirmation" => "abc"}
        )
        |> render_submit()

      assert result =~ "should be at least 4 character(s)"
    end
  end
end
