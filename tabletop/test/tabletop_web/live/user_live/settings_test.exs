defmodule TabletopWeb.UserLive.SettingsTest do
  use TabletopWeb.ConnCase, async: true

  alias Tabletop.Accounts
  import Phoenix.LiveViewTest
  import Tabletop.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Account Settings"
      assert html =~ "Change password"
    end

    test "stays reachable once sudo mode has lapsed", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: stale_login())
        |> live(~p"/users/settings")

      assert html =~ "Change password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "change password page" do
    test "redirects to log in when sudo mode has lapsed", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture(), token_authenticated_at: stale_login())
        |> get(~p"/users/settings/password")

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "You must re-authenticate to access this page."

      # Re-authenticating has to come back to the page that demanded it.
      assert get_session(conn, :user_return_to) == ~p"/users/settings/password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings/password")

      assert {:redirect, %{to: path}} = redirect
      assert path == ~p"/users/log-in"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "password",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "password",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "does not match password"
    end

    test "rejects the POST outright once sudo mode has lapsed", %{conn: conn, user: user} do
      offset_user_token(get_session(conn, :user_token), -30, :minute)
      new_password = valid_user_password()

      conn =
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute Accounts.get_user_by_email_and_password(user.email, new_password)
    end
  end

  # Anything older than the 20-minute sudo window (`Accounts.sudo_mode?/2`).
  defp stale_login, do: DateTime.add(DateTime.utc_now(:second), -30, :minute)
end
