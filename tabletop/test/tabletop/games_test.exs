defmodule Tabletop.GamesTest do
  use Tabletop.DataCase

  alias Tabletop.Games

  describe "games" do
    alias Tabletop.Games.Game

    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    @invalid_attrs %{title: nil, format: nil}

    test "list_games/1 returns all scoped games" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      {:ok, _} = Games.terminate_game(scope, game)
      other_game = game_fixture(scope)
      ids = Games.list_games(scope) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([game.id, other_game.id])
    end

    test "get_game!/2 returns the game with given id" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      fetched = Games.get_game!(scope, game.id)
      assert fetched.id == game.id
      assert fetched.title == game.title
      assert fetched.user.id == scope.user.id
    end

    test "create_game/2 with valid data creates a game" do
      valid_attrs = %{title: "some title"}
      scope = user_scope_fixture()

      assert {:ok, %Game{} = game} = Games.create_game(scope, valid_attrs)
      assert game.title == "some title"
      assert game.user_id == scope.user.id
    end

    test "create_game/2 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Games.create_game(scope, @invalid_attrs)
    end

    test "update_game/3 with valid data updates the game" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      update_attrs = %{title: "some updated title"}

      assert {:ok, %Game{} = game} = Games.update_game(scope, game, update_attrs)
      assert game.title == "some updated title"
    end

    test "update_game/3 with invalid scope raises" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      game = game_fixture(scope)

      assert_raise MatchError, fn ->
        Games.update_game(other_scope, game, %{})
      end
    end

    test "update_game/3 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      assert {:error, %Ecto.Changeset{}} = Games.update_game(scope, game, @invalid_attrs)
      assert game.id == Games.get_game!(scope, game.id).id
    end

    test "delete_game/2 deletes the game" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      assert {:ok, %Game{}} = Games.delete_game(scope, game)
      assert_raise Ecto.NoResultsError, fn -> Games.get_game!(scope, game.id) end
    end

    test "delete_game/2 with invalid scope raises" do
      scope = user_scope_fixture()
      other_scope = user_scope_fixture()
      game = game_fixture(scope)
      assert_raise MatchError, fn -> Games.delete_game(other_scope, game) end
    end

    test "change_game/2 returns a game changeset" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      assert %Ecto.Changeset{} = Games.change_game(scope, game)
    end
  end

  describe "join_game/2" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "sets user2 and status to active" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)

      assert {:ok, game} = Games.join_game(scope2, game)
      assert game.user2_id == scope2.user.id
      assert game.status == :active
    end

    test "cannot join own game" do
      scope = user_scope_fixture()
      game = game_fixture(scope)

      assert {:error, :own_game} = Games.join_game(scope, game)
    end

    test "cannot join a full game" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      scope3 = user_scope_fixture()
      game = game_fixture(scope1)

      assert {:ok, game} = Games.join_game(scope2, game)
      assert {:error, :game_full} = Games.join_game(scope3, game)
    end
  end

  describe "one active game per user constraint" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "create_game/2 refuses when the user already has a waiting game" do
      scope = user_scope_fixture()
      _game = game_fixture(scope)

      assert {:error, :already_in_game} =
               Games.create_game(scope, %{title: "second", format: :classic_constructed})
    end

    test "create_game/2 refuses when the user is the opponent in an active game" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, _} = Games.join_game(scope2, game)

      assert {:error, :already_in_game} =
               Games.create_game(scope2, %{title: "second", format: :classic_constructed})
    end

    test "create_game/2 succeeds after the previous game is finished" do
      scope = user_scope_fixture()
      game = game_fixture(scope)
      {:ok, _} = Games.terminate_game(scope, game)

      assert {:ok, _new} =
               Games.create_game(scope, %{title: "second", format: :classic_constructed})
    end

    test "join_game/2 refuses when the joiner already has a waiting game of their own" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      _own = game_fixture(scope2)
      target = game_fixture(scope1)

      assert {:error, :already_in_game} = Games.join_game(scope2, target)
    end

    test "reserve_join/2 refuses when the user already has a different active game" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      _own = game_fixture(scope2)
      target = game_fixture(scope1)

      assert {:error, :already_in_game} = Games.reserve_join(scope2, target)
    end

    test "reserve_join/2 is idempotent for the same user (LiveView dead+live mount)" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      target = game_fixture(scope1)

      assert {:ok, game1} = Games.reserve_join(scope2, target)
      assert game1.joining_user_id == scope2.user.id
      assert {:ok, game2} = Games.reserve_join(scope2, target)
      assert game2.joining_user_id == scope2.user.id
    end

    test "reserve_join/2 refuses when a different user already holds an unexpired reservation" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      scope3 = user_scope_fixture()
      target = game_fixture(scope1)

      assert {:ok, _} = Games.reserve_join(scope2, target)
      assert {:error, :unavailable} = Games.reserve_join(scope3, target)
    end

    test "DB-level partial unique index blocks duplicate active games for user1" do
      scope = user_scope_fixture()
      _game = game_fixture(scope)

      assert_raise Ecto.ConstraintError, ~r/games_one_active_per_user1/, fn ->
        %Tabletop.Games.Game{}
        |> Ecto.Changeset.change(%{
          title: "bypass",
          format: :classic_constructed,
          status: :waiting,
          user_id: scope.user.id
        })
        |> Tabletop.Repo.insert()
      end
    end
  end

  describe "terminate_game/2" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "marks both players as left and sets status to finished" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)

      assert {:ok, game} = Games.terminate_game(scope1, game)
      assert game.status == :finished
      assert not is_nil(game.user1_left_at)
      assert not is_nil(game.user2_left_at)
    end

    test "is idempotent on an already finished game" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)

      {:ok, game} = Games.terminate_game(scope1, game)
      original_user1_left = game.user1_left_at
      original_user2_left = game.user2_left_at

      assert {:ok, game} = Games.terminate_game(scope2, game)
      assert game.user1_left_at == original_user1_left
      assert game.user2_left_at == original_user2_left
    end
  end

  describe "rejoin_game/2" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "clears user1_left_at after terminate" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)
      {:ok, game} = Games.terminate_game(scope1, game)
      assert not is_nil(game.user1_left_at)

      game = Games.rejoin_game(scope1, game)
      assert is_nil(game.user1_left_at)
    end

    test "clears user2_left_at after terminate" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)
      {:ok, game} = Games.terminate_game(scope2, game)
      assert not is_nil(game.user2_left_at)

      game = Games.rejoin_game(scope2, game)
      assert is_nil(game.user2_left_at)
    end

    test "is a no-op when user hasn't left" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)

      assert {:ok, ^game} = Games.rejoin_game(scope1, game)
    end
  end

  describe "get_current_game_for_user/1" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "returns active game for user" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, _game} = Games.join_game(scope2, game)

      current = Games.get_current_game_for_user(scope1)
      assert current.id == game.id
    end

    test "returns waiting game for creator" do
      scope = user_scope_fixture()
      game = game_fixture(scope)

      current = Games.get_current_game_for_user(scope)
      assert current.id == game.id
    end

    test "returns nil for finished games" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)
      Games.terminate_game(scope1, game)

      assert is_nil(Games.get_current_game_for_user(scope1))
      assert is_nil(Games.get_current_game_for_user(scope2))
    end

    test "returns nil for nil scope" do
      assert is_nil(Games.get_current_game_for_user(nil))
    end
  end

  describe "list_joinable_games/2" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "excludes active games" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      scope3 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, _game} = Games.join_game(scope2, game)

      joinable = Games.list_joinable_games(scope3)
      refute Enum.any?(joinable, &(&1.id == game.id))
    end

    test "excludes finished games" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      scope3 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, game} = Games.join_game(scope2, game)
      Games.terminate_game(scope1, game)

      joinable = Games.list_joinable_games(scope3)
      refute Enum.any?(joinable, &(&1.id == game.id))
    end

    test "excludes own games" do
      scope = user_scope_fixture()
      game_fixture(scope)

      joinable = Games.list_joinable_games(scope)
      assert joinable == []
    end

    test "includes waiting games from other users" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)

      joinable = Games.list_joinable_games(scope2)
      assert Enum.any?(joinable, &(&1.id == game.id))
    end
  end
end
