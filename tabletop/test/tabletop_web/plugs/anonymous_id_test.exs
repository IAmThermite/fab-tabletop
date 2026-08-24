defmodule TabletopWeb.Plugs.AnonymousIdTest do
  use TabletopWeb.ConnCase, async: true

  alias TabletopWeb.Plugs.AnonymousId

  describe "call/2" do
    test "stores an anonymous id in the session when there isn't one", %{conn: conn} do
      conn = conn |> init_test_session(%{}) |> AnonymousId.call([])

      assert "anon:" <> _ = get_session(conn, AnonymousId.session_key())
    end

    test "keeps an existing id so it stays stable across requests", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{AnonymousId.session_key() => "anon:existing"})
        |> AnonymousId.call([])

      assert get_session(conn, AnonymousId.session_key()) == "anon:existing"
    end

    test "runs in the browser pipeline", %{conn: conn} do
      conn = get(conn, ~p"/camera-setup")

      assert "anon:" <> _ = get_session(conn, AnonymousId.session_key())
    end
  end

  describe "generate/0" do
    test "is url-safe — the id becomes part of a PubSub topic and :pg group key" do
      "anon:" <> random = AnonymousId.generate()

      assert random == URI.encode_www_form(random)
    end

    test "returns a distinct id per call" do
      assert AnonymousId.generate() != AnonymousId.generate()
    end
  end
end
