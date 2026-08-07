defmodule Tabletop.Games.HeroLeaderboardTest do
  # Not async: the cache and the server that owns it are global, so a populated
  # cache would otherwise be visible to every other test. The shared sandbox a
  # sync test gets is also what lets the server reach the test's data at all.
  use Tabletop.DataCase, async: false

  import Tabletop.AccountsFixtures, only: [user_scope_fixture: 0]
  import Tabletop.GamesFixtures

  alias Tabletop.Games
  alias Tabletop.Games.HeroLeaderboard

  setup do
    # Leave the cache cold for everyone else, whatever this test put in it.
    on_exit(&HeroLeaderboard.invalidate/0)
    HeroLeaderboard.invalidate()
  end

  defp two_heroes, do: Tabletop.Heroes.legal_for(:classic_constructed)

  test "computes inline while the cache is cold" do
    [hero | _] = two_heroes()
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero.slug})

    assert HeroLeaderboard.get()[:classic_constructed] == [{hero.slug, 1}]
  end

  test "serves the cached ranking rather than recomputing it" do
    [hero | _] = two_heroes()
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero.slug})

    assert HeroLeaderboard.refresh()[:classic_constructed] == [{hero.slug, 1}]

    # A game created after the refresh must not show up until the next one —
    # that staleness is the whole point of the cache.
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero.slug})

    assert HeroLeaderboard.get()[:classic_constructed] == [{hero.slug, 1}]
    assert HeroLeaderboard.refresh()[:classic_constructed] == [{hero.slug, 2}]
  end

  test "invalidate drops the cache so the next read recomputes" do
    [hero | _] = two_heroes()
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero.slug})
    HeroLeaderboard.refresh()

    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero.slug})
    HeroLeaderboard.invalidate()

    assert HeroLeaderboard.get()[:classic_constructed] == [{hero.slug, 2}]
  end

  test "activity_stats reads its leaderboard through the cache" do
    [hero1, hero2 | _] = two_heroes()
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero1.slug})
    HeroLeaderboard.refresh()

    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero2.slug})

    stats = Games.activity_stats()

    # The live counts are queried per call, the leaderboard is not.
    assert stats.open_total == 2
    assert stats.popular_heroes[:classic_constructed] == [{hero1.slug, 1}]
  end

  test "ranks ties alphabetically so the order is stable across refreshes" do
    [hero1, hero2 | _] = two_heroes() |> Enum.sort_by(& &1.slug)
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero1.slug})
    game_fixture(user_scope_fixture(), %{format: :classic_constructed, hero: hero2.slug})

    assert HeroLeaderboard.get()[:classic_constructed] == [{hero1.slug, 1}, {hero2.slug, 1}]
  end
end
