defmodule Tabletop.GamesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Tabletop.Games` context.
  """

  @doc """
  Generate a game.

  A hero is required on created games, so we default one that's legal in the
  (possibly overridden) format unless the caller supplies their own `:hero`.
  """
  def game_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "Game Time",
        format: :classic_constructed
      })

    attrs = Map.put_new_lazy(attrs, :hero, fn -> default_hero_for(attrs.format) end)

    {:ok, game} = Tabletop.Games.create_game(scope, attrs)
    game
  end

  defp default_hero_for(format) do
    case Tabletop.Heroes.legal_for(format) do
      [hero | _] -> hero.slug
      [] -> nil
    end
  end
end
