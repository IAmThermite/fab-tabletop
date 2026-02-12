defmodule Tabletop.GamesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Tabletop.Games` context.
  """

  @doc """
  Generate a game.
  """
  def game_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "some name"
      })

    {:ok, game} = Tabletop.Games.create_game(scope, attrs)
    game
  end
end
