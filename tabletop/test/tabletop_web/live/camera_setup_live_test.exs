defmodule TabletopWeb.CameraSetupLiveTest do
  use TabletopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TabletopWeb.CameraRelayToken

  # The desktop and the phone must agree on the `camera_relay:<user_id>` topic.
  # The phone's half of that comes from the QR code, which is rendered inside the
  # `phx-update="ignore"` settings dialog and therefore *never patched* — the
  # user always scans the dead render's QR. The desktop's half comes from
  # `data-relay-user-id`, which the JS hook reads after the connected render.
  # So the two renders have to resolve to the same id, or the phone joins a relay
  # topic the desktop isn't in and sits on "Waiting for desktop..." forever.
  describe "relay identity" do
    test "is stable across the dead and connected renders for anonymous visitors", %{conn: conn} do
      conn = get(conn, ~p"/camera-setup")
      dead_id = relay_user_id(html_response(conn, 200))

      {:ok, _lv, connected_html} = live(conn)

      assert relay_user_id(connected_html) == dead_id
      assert "anon:" <> _ = dead_id
    end

    test "survives a remount of the same session", %{conn: conn} do
      conn = get(conn, ~p"/camera-setup")
      first = relay_user_id(html_response(conn, 200))

      conn = conn |> recycle() |> get(~p"/camera-setup")

      assert relay_user_id(html_response(conn, 200)) == first
    end

    test "is the logged-in user's id when there is one", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

      conn = get(conn, ~p"/camera-setup")

      assert relay_user_id(html_response(conn, 200)) == user.id
    end
  end

  describe "camera relay token" do
    test "round-trips the relay user id" do
      token = CameraRelayToken.sign(TabletopWeb.Endpoint, "anon:abc123")

      assert {:ok, "anon:abc123"} = CameraRelayToken.verify(TabletopWeb.Endpoint, token)
    end

    test "outlives the page it is rendered on" do
      # The QR is minted once per page render and never refreshed (it sits inside
      # the phx-update="ignore" dialog), so the token has to survive a
      # full-length session at the table.
      two_hours_ago = System.system_time(:millisecond) - 2 * 60 * 60 * 1000

      token =
        Phoenix.Token.sign(TabletopWeb.Endpoint, "camera relay", "anon:abc123",
          signed_at: two_hours_ago
        )

      assert {:ok, "anon:abc123"} = CameraRelayToken.verify(TabletopWeb.Endpoint, token)
    end

    test "rejects a tampered token" do
      assert {:error, :invalid} = CameraRelayToken.verify(TabletopWeb.Endpoint, "nonsense")
    end
  end

  defp relay_user_id(html) do
    [_, id] = Regex.run(~r/data-relay-user-id="([^"]*)"/, html)
    id
  end
end
