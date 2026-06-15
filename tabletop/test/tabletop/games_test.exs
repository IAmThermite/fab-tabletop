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

    test "get_game!/2 raises when the scoped user is not a participant" do
      owner_scope = user_scope_fixture()
      outsider_scope = user_scope_fixture()
      game = game_fixture(owner_scope)

      assert_raise Ecto.NoResultsError, fn ->
        Games.get_game!(outsider_scope, game.id)
      end
    end

    test "get_game/2 returns :not_found when the scoped user is not a participant" do
      owner_scope = user_scope_fixture()
      outsider_scope = user_scope_fixture()
      game = game_fixture(owner_scope)

      assert {:error, :not_found} = Games.get_game(outsider_scope, game.id)
    end

    test "get_game/2 returns {:ok, game} when the scoped user is a participant" do
      scope = user_scope_fixture()
      game = game_fixture(scope)

      assert {:ok, fetched} = Games.get_game(scope, game.id)
      assert fetched.id == game.id
    end

    test "fetch_game/1 returns the game regardless of participation" do
      owner_scope = user_scope_fixture()
      game = game_fixture(owner_scope)

      assert {:ok, fetched} = Games.fetch_game(game.id)
      assert fetched.id == game.id
    end

    test "create_game/2 with valid data creates a game" do
      valid_attrs = %{title: "some title"}
      scope = user_scope_fixture()

      assert {:ok, %Game{} = game} = Games.create_game(scope, valid_attrs)
      assert game.title == "some title"
      assert game.user_id == scope.user.id
    end

    test "create_game/2 defaults language to the default when not provided" do
      scope = user_scope_fixture()
      assert {:ok, %Game{} = game} = Games.create_game(scope, %{title: "some title"})
      assert game.language == Tabletop.Languages.default()
    end

    test "create_game/2 accepts a language" do
      scope = user_scope_fixture()

      assert {:ok, %Game{} = game} =
               Games.create_game(scope, %{title: "fr game", language: :fra})

      assert game.language == :fra
    end

    test "create_game/2 rejects an unknown language" do
      scope = user_scope_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.create_game(scope, %{title: "x", language: :klingon})

      assert %{language: ["is invalid"]} = errors_on(changeset)
    end

    test "create_game/2 with invalid data returns error changeset" do
      scope = user_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Games.create_game(scope, @invalid_attrs)
    end

    test "create_game/2 accepts the blitz format" do
      scope = user_scope_fixture()

      assert {:ok, %Game{} = game} =
               Games.create_game(scope, %{title: "blitz game", format: :blitz})

      assert game.format == :blitz
    end

    test "create_game/2 accepts a hero legal in the chosen format" do
      scope = user_scope_fixture()
      [hero | _] = Tabletop.Heroes.legal_for(:classic_constructed)

      assert {:ok, %Game{} = game} =
               Games.create_game(scope, %{
                 title: "hero game",
                 format: :classic_constructed,
                 hero: hero.slug
               })

      assert game.hero == hero.slug
    end

    test "create_game/2 rejects a hero not legal in the chosen format" do
      scope = user_scope_fixture()
      illegal = Enum.find(Tabletop.Heroes.all(), &(:blitz not in &1.formats))

      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.create_game(scope, %{title: "x", format: :blitz, hero: illegal.slug})

      assert %{hero: ["is not legal in this format"]} = errors_on(changeset)
    end

    test "create_game/2 rejects an unrecognized hero" do
      scope = user_scope_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Games.create_game(scope, %{title: "x", hero: "not-a-real-hero"})

      assert %{hero: ["is not a recognized hero"]} = errors_on(changeset)
    end

    test "create_game/2 allows a hidden (blank) hero" do
      scope = user_scope_fixture()

      assert {:ok, %Game{} = game} = Games.create_game(scope, %{title: "no hero", hero: ""})
      assert game.hero == nil
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

  describe "get_last_created_game/1" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "returns the user's created game" do
      scope = user_scope_fixture()
      game = game_fixture(scope)

      assert Games.get_last_created_game(scope).id == game.id
    end

    test "ignores games the user only joined" do
      creator = user_scope_fixture()
      joiner = user_scope_fixture()
      game = game_fixture(creator)
      {:ok, _} = Games.join_game(joiner, game)

      assert is_nil(Games.get_last_created_game(joiner))
      assert Games.get_last_created_game(creator).id == game.id
    end

    test "returns the most recent created game when several exist" do
      scope = user_scope_fixture()
      old = game_fixture(scope)
      {:ok, _} = Games.terminate_game(scope, old)

      # Backdate the finished game so ordering is unambiguous, then create a new one.
      old
      |> Ecto.Changeset.change(inserted_at: ~U[2020-01-01 00:00:00Z])
      |> Tabletop.Repo.update!()

      new = game_fixture(scope)

      assert Games.get_last_created_game(scope).id == new.id
    end

    test "returns nil for a user with no games" do
      scope = user_scope_fixture()
      assert is_nil(Games.get_last_created_game(scope))
    end

    test "returns nil for nil scope" do
      assert is_nil(Games.get_last_created_game(nil))
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

  describe "activity_stats/1" do
    import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
    import Tabletop.GamesFixtures

    test "counts open games grouped by format with a matching total" do
      game_fixture(user_scope_fixture(), %{format: :classic_constructed})
      game_fixture(user_scope_fixture(), %{format: :classic_constructed})
      game_fixture(user_scope_fixture(), %{format: :blitz})

      stats = Games.activity_stats()

      assert stats.open_by_format == %{classic_constructed: 2, blitz: 1}
      assert stats.open_total == 3
    end

    test "excludes private and reserved games from the open counts" do
      game_fixture(user_scope_fixture(), %{format: :classic_constructed})
      game_fixture(user_scope_fixture(), %{format: :classic_constructed, private: true})

      reserved_owner = user_scope_fixture()
      reserver = user_scope_fixture()
      reserved = game_fixture(reserved_owner, %{format: :blitz})
      {:ok, _} = Games.reserve_join(reserver, reserved)

      stats = Games.activity_stats()

      assert stats.open_by_format == %{classic_constructed: 1}
      assert stats.open_total == 1
    end

    test "counts active games and the players seated in them" do
      scope1 = user_scope_fixture()
      scope2 = user_scope_fixture()
      game = game_fixture(scope1)
      {:ok, _} = Games.join_game(scope2, game)

      stats = Games.activity_stats()

      assert stats.active_games == 1
      assert stats.active_players == 2
      # An active game no longer waits for an opponent.
      assert stats.open_total == 0
    end

    test "ranks popular heroes per format, most popular first, ignoring blank heroes" do
      [hero1, hero2 | _] = Tabletop.Heroes.legal_for(:classic_constructed)

      game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero1.slug})
      game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero1.slug})
      game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero2.slug})
      game_fixture(user_scope_fixture(), %{format: :classic_constructed})

      stats = Games.activity_stats()

      assert stats.popular_heroes[:classic_constructed] == [
               {hero1.slug, 2},
               {hero2.slug, 1}
             ]
    end

    test "excludes games created outside the window" do
      [hero | _] = Tabletop.Heroes.legal_for(:classic_constructed)
      game = game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero.slug})

      old = DateTime.add(DateTime.utc_now(), -8 * 24 * 60 * 60, :second)

      game
      |> Ecto.Changeset.change(inserted_at: DateTime.truncate(old, :second))
      |> Tabletop.Repo.update!()

      stats = Games.activity_stats()

      assert Map.get(stats.popular_heroes, :classic_constructed, []) == []
    end
  end
end
