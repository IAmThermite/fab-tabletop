defmodule TabletopWeb.GameChannelTest do
  # Not async: channel processes need the sandbox in shared mode, and the `:pg`
  # groups these tests exercise are global.
  use TabletopWeb.ChannelCase, async: false

  import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
  import Tabletop.GamesFixtures

  alias Tabletop.Games
  alias TabletopWeb.UserSocket

  setup do
    host = user_scope_fixture()
    guest = user_scope_fixture()

    game = game_fixture(host)
    [hero | _] = Tabletop.Heroes.legal_for(game.format)
    {:ok, game} = Games.join_game(guest, game, hero.slug)

    %{game: game, host_id: host.user.id, guest_id: guest.user.id}
  end

  describe "join/3" do
    test "admits both players and refuses everyone else", ctx do
      assert {:ok, _, _} = join_as(ctx.host_id, ctx.game.id)
      assert {:ok, _, _} = join_as(ctx.guest_id, ctx.game.id)

      stranger = user_scope_fixture()
      assert {:error, %{reason: "unauthorized"}} = join_as(stranger.user.id, ctx.game.id)
    end
  end

  describe "one socket per player" do
    test "a second tab supersedes the first", ctx do
      {:ok, _, first} = join_as(ctx.host_id, ctx.game.id)
      ref = Process.monitor(first.channel_pid)

      {:ok, _, _second} = join_as(ctx.host_id, ctx.game.id)

      assert_push "superseded", %{}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    test "the opponent is not told the player left", ctx do
      {:ok, _, _host} = join_as(ctx.host_id, ctx.game.id)
      {:ok, _, _guest} = join_as(ctx.guest_id, ctx.game.id)

      {:ok, _, _host_second_tab} = join_as(ctx.host_id, ctx.game.id)

      # `assert_push` returns only once the eviction has run, so a `peer_left`
      # would already be on the wire by the time we refute it.
      assert_push "superseded", %{}

      # The player never left — their replacement is on the topic and about to
      # renegotiate. A `peer_left` here would make the opponent tear down the
      # connection being rebuilt, with nothing left to trigger another offer.
      refute_broadcast "peer_left", %{}
    end

    test "the replacement announces itself so the opponent re-offers", ctx do
      {:ok, _, _host} = join_as(ctx.host_id, ctx.game.id)
      {:ok, _, _guest} = join_as(ctx.guest_id, ctx.game.id)
      host_id = ctx.host_id

      {:ok, _, _host_second_tab} = join_as(ctx.host_id, ctx.game.id)

      assert_broadcast "peer_joined", %{user_id: ^host_id}
    end

    test "the two players do not evict each other", ctx do
      {:ok, _, host} = join_as(ctx.host_id, ctx.game.id)
      {:ok, _, guest} = join_as(ctx.guest_id, ctx.game.id)

      refute_push "superseded", %{}
      assert Process.alive?(host.channel_pid)
      assert Process.alive?(guest.channel_pid)
    end
  end

  describe "terminate/2" do
    test "a genuine leave still announces peer_left", ctx do
      {:ok, _, host} = join_as(ctx.host_id, ctx.game.id)
      {:ok, _, _guest} = join_as(ctx.guest_id, ctx.game.id)
      host_id = ctx.host_id

      # `leave/1` exits the channel with `{:shutdown, :left}`, and channels are
      # linked to the test process — without unlinking, that exit races the
      # assertions below and fails the test intermittently.
      Process.unlink(host.channel_pid)
      ref = leave(host)
      assert_reply ref, :ok

      assert_broadcast "peer_left", %{user_id: ^host_id}
    end
  end

  defp join_as(user_id, game_id) do
    UserSocket
    |> socket("user_socket:#{user_id}", %{user_id: user_id, socket_kind: :user})
    |> subscribe_and_join(TabletopWeb.GameChannel, "game:#{game_id}")
  end
end
