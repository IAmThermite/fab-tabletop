defmodule TabletopWeb.CameraRelayChannelTest do
  # Not async: the `:pg` groups these tests exercise are global.
  use TabletopWeb.ChannelCase, async: false

  import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]

  alias TabletopWeb.UserSocket

  setup do
    scope = user_scope_fixture()
    %{user_id: scope.user.id}
  end

  describe "join/3" do
    test "refuses a socket for a different user's relay topic", %{user_id: user_id} do
      other = user_scope_fixture()

      assert {:error, %{reason: "unauthorized"}} = join_as(other.user.id, :user, user_id)
    end
  end

  describe "one socket per end of the relay" do
    test "a second desktop tab supersedes the first", %{user_id: user_id} do
      {:ok, _, first} = join_as(user_id, :user, user_id)
      ref = Process.monitor(first.channel_pid)

      {:ok, _, _second} = join_as(user_id, :user, user_id)

      assert_push "superseded", %{}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    test "the phone keeps its seat when the desktop is superseded", %{user_id: user_id} do
      # Both ends of a relay authenticate as the same user, so only the socket
      # kind separates them — a desktop tab must not evict the phone.
      {:ok, _, phone} = join_as(user_id, :phone, user_id)
      {:ok, _, _desktop} = join_as(user_id, :user, user_id)

      {:ok, _, _desktop_second_tab} = join_as(user_id, :user, user_id)

      assert_push "superseded", %{}
      assert Process.alive?(phone.channel_pid)

      # The phone never lost its peer; announcing otherwise would drop the feed
      # the replacement desktop is about to renegotiate for.
      refute_broadcast "peer_left", %{}
    end

    test "a second phone supersedes the first phone", %{user_id: user_id} do
      {:ok, _, first} = join_as(user_id, :phone, user_id)
      ref = Process.monitor(first.channel_pid)

      {:ok, _, _second} = join_as(user_id, :phone, user_id)

      assert_push "superseded", %{}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    test "one desktop and one phone coexist", %{user_id: user_id} do
      {:ok, _, desktop} = join_as(user_id, :user, user_id)
      {:ok, _, phone} = join_as(user_id, :phone, user_id)

      refute_push "superseded", %{}
      assert Process.alive?(desktop.channel_pid)
      assert Process.alive?(phone.channel_pid)
    end
  end

  defp join_as(user_id, socket_kind, relay_user_id) do
    UserSocket
    |> socket("user_socket:#{user_id}", %{user_id: user_id, socket_kind: socket_kind})
    |> subscribe_and_join(TabletopWeb.CameraRelayChannel, "camera_relay:#{relay_user_id}")
  end
end
