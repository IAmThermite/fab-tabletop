defmodule Tabletop.Games do
  @moduledoc """
  The Games context.
  """

  import Ecto.Query, warn: false
  alias Tabletop.Repo

  alias Tabletop.Games.Game
  alias Tabletop.Accounts.Scope

  @doc """
  Subscribes to scoped notifications about any game changes.

  The broadcasted messages match the pattern:

    * {:created, %Game{}}
    * {:updated, %Game{}}
    * {:deleted, %Game{}}

  """
  def subscribe_games(%Scope{} = _scope) do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, "games")
  end

  def subscribe_games(nil) do
    Phoenix.PubSub.subscribe(Tabletop.PubSub, "games")
  end

  defp broadcast_game(%Scope{} = _scope, message) do
    Phoenix.PubSub.broadcast(Tabletop.PubSub, "games", message)
  end

  @doc """
  Returns the list of games.

  ## Examples

      iex> list_games(scope)
      [%Game{}, ...]

  """
  def list_games(%Scope{} = _scope) do
    Repo.all(Game)
  end

  @doc """
  Returns the list of joinable games (no opponent yet, not created by current user).
  Optionally filters by format.
  """
  def list_joinable_games(scope, format_filter \\ "")

  def list_joinable_games(%Scope{} = scope, format_filter) do
    query =
      from g in Game,
        where: is_nil(g.user2_id),
        where: g.user_id != ^scope.user.id,
        order_by: [desc: g.inserted_at],
        preload: [:user]

    query =
      if format_filter != "" do
        from g in query, where: g.format == ^format_filter
      else
        query
      end

    Repo.all(query)
  end

  def list_joinable_games(nil, format_filter) do
    query =
      from g in Game,
        where: is_nil(g.user2_id),
        order_by: [desc: g.inserted_at],
        preload: [:user]

    query =
      if format_filter != "" do
        from g in query, where: g.format == ^format_filter
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets a single game.

  Raises `Ecto.NoResultsError` if the Game does not exist.

  ## Examples

      iex> get_game!(scope, 123)
      %Game{}

      iex> get_game!(scope, 456)
      ** (Ecto.NoResultsError)

  """
  def get_game!(%Scope{} = _scope, id) do
    Repo.get_by!(Game, id: id) |> Repo.preload([:user, :user2])
  end

  @doc """
  Creates a game.

  ## Examples

      iex> create_game(scope, %{field: value})
      {:ok, %Game{}}

      iex> create_game(scope, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_game(%Scope{} = scope, attrs) do
    with {:ok, game = %Game{}} <-
           %Game{}
           |> Game.changeset(attrs, scope)
           |> Repo.insert() do
      broadcast_game(scope, {:created, game})
      {:ok, game}
    end
  end

  @doc """
  Updates a game.

  ## Examples

      iex> update_game(scope, game, %{field: new_value})
      {:ok, %Game{}}

      iex> update_game(scope, game, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_game(%Scope{} = scope, %Game{} = game, attrs) do
    true = game.user_id == scope.user.id

    with {:ok, game = %Game{}} <-
           game
           |> Game.changeset(attrs, scope)
           |> Repo.update() do
      broadcast_game(scope, {:updated, game})
      {:ok, game}
    end
  end

  @doc """
  Deletes a game.

  ## Examples

      iex> delete_game(scope, game)
      {:ok, %Game{}}

      iex> delete_game(scope, game)
      {:error, %Ecto.Changeset{}}

  """
  def delete_game(%Scope{} = scope, %Game{} = game) do
    true = game.user_id == scope.user.id

    with {:ok, game = %Game{}} <-
           Repo.delete(game) do
      broadcast_game(scope, {:deleted, game})
      {:ok, game}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking game changes.

  ## Examples

      iex> change_game(scope, game)
      %Ecto.Changeset{data: %Game{}}

  """
  def change_game(%Scope{} = scope, %Game{} = game, attrs \\ %{}) do
    true = game.user_id == scope.user.id

    Game.changeset(game, attrs, scope)
  end

  @doc """
  Joins a game by setting the current user as user2 (opponent).
  """
  def join_game(%Scope{} = scope, %Game{} = game) do
    cond do
      game.user_id == scope.user.id ->
        {:error, :own_game}

      game.user2_id != nil ->
        {:error, :game_full}

      true ->
        game
        |> Ecto.Changeset.change(%{user2_id: scope.user.id})
        |> Repo.update()
        |> case do
          {:ok, game} ->
            broadcast_game(scope, {:updated, game})
            {:ok, game}

          error ->
            error
        end
    end
  end

  def user_part_of_game?(%Scope{} = scope, %Game{} = game) do
    game.user_id == scope.user.id || game.user2_id == scope.user.id
  end
end
