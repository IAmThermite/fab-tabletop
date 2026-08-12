defmodule TabletopWeb.UserSocketTest do
  use TabletopWeb.ChannelCase, async: true

  alias TabletopWeb.CameraRelayToken
  alias TabletopWeb.UserSocket

  @user_id "0195f6b5-2b26-7f4f-8f6a-7f2c1d3e4a5b"

  describe "connect/3" do
    test "a user token yields a `:user` socket" do
      token = Phoenix.Token.sign(TabletopWeb.Endpoint, "user socket", @user_id)

      assert {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert socket.assigns.user_id == @user_id
      # The relay topic is keyed by user id and holds this user's desktop *and*
      # phone, so `socket_kind` is the only thing telling the two ends apart —
      # see TabletopWeb.CameraRelayChannel.
      assert socket.assigns.socket_kind == :user
    end

    test "a camera relay token yields a `:phone` socket" do
      token = CameraRelayToken.sign(TabletopWeb.Endpoint, @user_id)

      assert {:ok, socket} = connect(UserSocket, %{"camera_relay_token" => token})
      assert socket.assigns.user_id == @user_id
      assert socket.assigns.socket_kind == :phone
    end

    test "refuses a garbage token" do
      assert :error = connect(UserSocket, %{"token" => "nope"})
      assert :error = connect(UserSocket, %{"camera_relay_token" => "nope"})
      assert :error = connect(UserSocket, %{})
    end

    test "refuses a relay token presented as a user token" do
      # Different salts, so neither verifier accepts the other's token.
      relay_token = CameraRelayToken.sign(TabletopWeb.Endpoint, @user_id)
      user_token = Phoenix.Token.sign(TabletopWeb.Endpoint, "user socket", @user_id)

      assert :error = connect(UserSocket, %{"token" => relay_token})
      assert :error = connect(UserSocket, %{"camera_relay_token" => user_token})
    end
  end
end
