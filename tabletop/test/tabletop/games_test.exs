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
      other_game = game_fixture(scope)
      assert Games.list_games(scope) == [game, other_game]
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
end
