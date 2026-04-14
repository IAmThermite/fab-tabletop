defmodule TabletopWeb.UserLive.ConfirmationPendingTest do
  use TabletopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletop.AccountsFixtures

  describe "Confirmation pending page" do
    test "redirects to login if no email in flash", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/users/confirmation-pending")
    end

    test "renders confirmation page with email from flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/confirmation-pending")

      assert html =~ "Thanks for registering"
      assert html =~ email
      assert html =~ "Resend Confirmation Email"
      assert html =~ "Log in"
    end

    test "resend button sends confirmation email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, pending_lv, _html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/confirmation-pending")

      result = pending_lv |> element("button", "Resend Confirmation Email") |> render_click()

      assert result =~ "you will receive a confirmation email shortly"
    end
  end
end
