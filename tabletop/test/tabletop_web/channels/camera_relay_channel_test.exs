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

  describe "one end offers" do
    test "the phone is asked when the desktop arrives", %{user_id: user_id} do
      {:ok, _, _phone} = join_as(user_id, :phone, user_id)
      refute_push "make_offer", %{}

      {:ok, _, _desktop} = join_as(user_id, :user, user_id)

      assert_push "make_offer", %{}
      refute_push "make_offer", %{}
    end

    test "the phone is asked when it is the one arriving", %{user_id: user_id} do
      {:ok, _, _desktop} = join_as(user_id, :user, user_id)
      refute_push "make_offer", %{}

      {:ok, _, _phone} = join_as(user_id, :phone, user_id)

      assert_push "make_offer", %{}
      refute_push "make_offer", %{}
    end

    test "an arrival both ends see still produces one offer", %{user_id: user_id} do
      {:ok, _, _desktop} = join_as(user_id, :user, user_id)
      {:ok, _, _phone} = join_as(user_id, :phone, user_id)
      assert_push "make_offer", %{}

      # Both ends passing the `has_peer` check before either joined the group.
      # Only the phone may answer that with an offer — the desktop has no
      # camera tracks to put in one, and two offers would close each other's
      # connections.
      TabletopWeb.Endpoint.broadcast!("camera_relay:#{user_id}", "peer_joined", %{})

      assert_push "make_offer", %{}
      refute_push "make_offer", %{}
    end
  end

  describe "terminate/2" do
    test "a drained socket does not announce peer_left", %{user_id: user_id} do
      {:ok, _, desktop} = join_as(user_id, :user, user_id)
      {:ok, _, _phone} = join_as(user_id, :phone, user_id)

      # What Phoenix's socket drainer does on shutdown. The phone goes on
      # sending to the desktop peer-to-peer across a restart, so announcing a
      # departure would drop the board camera for a deploy it never noticed.
      Process.unlink(desktop.channel_pid)
      ref = Process.monitor(desktop.channel_pid)
      send(desktop.channel_pid, %Phoenix.Socket.Broadcast{event: "phx_drain"})

      assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, :draining}}
      refute_broadcast "peer_left", %{}
    end
  end

  defp join_as(user_id, socket_kind, relay_user_id) do
    UserSocket
    |> socket("user_socket:#{user_id}", %{user_id: user_id, socket_kind: socket_kind})
    |> subscribe_and_join(TabletopWeb.CameraRelayChannel, "camera_relay:#{relay_user_id}")
  end
end
