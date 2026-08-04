defmodule TabletopWeb.PageControllerTest do
  use TabletopWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Games to join"
  end

  test "GET /about", %{conn: conn} do
    conn = get(conn, ~p"/about")
    assert html_response(conn, 200) =~ "How to use FaB Tabletop"
  end

  describe "policy pages" do
    test "GET /privacy", %{conn: conn} do
      html = conn |> get(~p"/privacy") |> html_response(200)

      assert html =~ "Privacy Policy"
      assert html =~ "never recorded or stored"
    end

    test "GET /terms", %{conn: conn} do
      html = conn |> get(~p"/terms") |> html_response(200)

      assert html =~ "Terms of Service"
      assert html =~ "Not affiliated with Legend Story Studios"
    end

    test "GET /code-of-conduct", %{conn: conn} do
      html = conn |> get(~p"/code-of-conduct") |> html_response(200)

      assert html =~ "Code of Conduct"
      assert html =~ "Reporting and consequences"
    end

    test "each policy page links to the other two", %{conn: conn} do
      for path <- [~p"/privacy", ~p"/terms", ~p"/code-of-conduct"] do
        html = conn |> get(path) |> html_response(200)

        # The footer alone links all three, so every page reaches the others
        # regardless of what its body cross-references.
        assert html =~ ~s|href="/privacy"|
        assert html =~ ~s|href="/terms"|
        assert html =~ ~s|href="/code-of-conduct"|
      end
    end
  end
end
