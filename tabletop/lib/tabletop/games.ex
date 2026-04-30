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

  defp broadcast_game_session(game_id, message, sender_id) do
    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{game_id}",
      {:game_update, message, sender_id}
    )
  end

  @doc """
  Returns the list of games.

  ## Examples

      iex> list_games(scope)
      [%Game{}, ...]

  """
  def list_games(%Scope{user: user}) do
    Game |> where(user_id: ^user.id) |> Repo.all()
  end

  @doc """
  Returns the list of joinable games (no opponent yet, not created by current user).
  Optionally filters by format.
  """
  def list_joinable_games(scope, format_filter \\ "")

  def list_joinable_games(%Scope{} = scope, format_filter) do
    now = DateTime.utc_now()

    query =
      from g in Game,
        where: g.status == :waiting,
        where: is_nil(g.user2_id),
        where: g.user_id != ^scope.user.id,
        where: is_nil(g.joining_user_id) or g.joining_expires_at < ^now,
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
    now = DateTime.utc_now()

    query =
      from g in Game,
        where: g.status == :waiting,
        where: is_nil(g.user2_id),
        where: is_nil(g.joining_user_id) or g.joining_expires_at < ^now,
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
    case get_current_game_for_user(scope) do
      nil ->
        with {:ok, game = %Game{}} <-
               %Game{}
               |> Game.changeset(attrs, scope)
               |> Repo.insert() do
          broadcast_game(scope, {:created, game})
          {:ok, game}
        end

      %Game{} ->
        {:error, :already_in_game}
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
  Reserves a join slot for a user entering the pre-join screen.
  Uses an atomic conditional UPDATE to prevent race conditions.
  """
  def reserve_join(%Scope{} = scope, %Game{} = game) do
    if user_in_other_game?(scope, game) do
      {:error, :already_in_game}
    else
      do_reserve_join(scope, game)
    end
  end

  defp do_reserve_join(%Scope{} = scope, %Game{} = game) do
    now = DateTime.utc_now()
    expires = DateTime.add(now, 120, :second)
    user_id = scope.user.id

    from(g in Game,
      where: g.id == ^game.id,
      where: g.status == :waiting,
      where: is_nil(g.user2_id),
      where: g.user_id != ^user_id,
      where: is_nil(g.joining_user_id) or g.joining_expires_at < ^now
    )
    |> Repo.update_all(set: [joining_user_id: user_id, joining_expires_at: expires])
    |> case do
      {1, _} ->
        game = Repo.get!(Game, game.id) |> Repo.preload([:user, :user2])
        broadcast_game(scope, {:updated, game})
        {:ok, game}

      {0, _} ->
        {:error, :unavailable}
    end
  end

  @doc """
  Releases a join reservation. Called when user leaves the pre-join screen.
  """
  def release_reservation(%Scope{} = scope, game_id) do
    {count, _} =
      from(g in Game,
        where: g.id == ^game_id,
        where: g.joining_user_id == ^scope.user.id
      )
      |> Repo.update_all(set: [joining_user_id: nil, joining_expires_at: nil])

    if count > 0 do
      game = Repo.get!(Game, game_id) |> Repo.preload([:user, :user2])
      broadcast_game(scope, {:updated, game})
    end

    :ok
  end

  @doc """
  Joins a game by setting the current user as user2 (opponent).
  Verifies the user holds the join reservation (or no reservation exists).
  """
  def join_game(%Scope{} = scope, %Game{} = game) do
    user_id = scope.user.id

    cond do
      game.status == :finished ->
        {:error, :finished}

      game.user_id == user_id ->
        {:error, :own_game}

      game.user2_id != nil ->
        {:error, :game_full}

      user_in_other_game?(scope, game) ->
        {:error, :already_in_game}

      true ->
        {count, _} =
          from(g in Game,
            where: g.id == ^game.id,
            where: g.status == :waiting,
            where: is_nil(g.user2_id),
            where: g.joining_user_id == ^user_id or is_nil(g.joining_user_id)
          )
          |> Repo.update_all(
            set: [
              user2_id: user_id,
              status: :active,
              joining_user_id: nil,
              joining_expires_at: nil
            ]
          )

        case count do
          1 ->
            game = Repo.get!(Game, game.id) |> Repo.preload([:user, :user2])
            broadcast_game(scope, {:updated, game})
            {:ok, game}

          0 ->
            {:error, :unavailable}
        end
    end
  end

  @doc """
  Terminates a game, marking both players as left and setting status to :finished.
  Broadcasts game_ended to the game session and an update to the games topic.
  """
  def terminate_game(%Scope{} = scope, %Game{} = game) do
    now = DateTime.utc_now()

    changes =
      %{status: :finished}
      |> then(fn c ->
        if is_nil(game.user1_left_at), do: Map.put(c, :user1_left_at, now), else: c
      end)
      |> then(fn c ->
        if is_nil(game.user2_left_at), do: Map.put(c, :user2_left_at, now), else: c
      end)

    game
    |> Ecto.Changeset.change(changes)
    |> Repo.update()
    |> case do
      {:ok, game} ->
        game = Repo.preload(game, [:user, :user2])
        broadcast_game(scope, {:updated, game})
        broadcast_game_session(game.id, "game_ended", scope.user.id)
        Tabletop.Games.GameSession.stop(game.id)
        {:ok, game}

      error ->
        error
    end
  end

  @doc """
  Clears a user's left_at timestamp so they can rejoin an active game.
  """
  def rejoin_game(%Scope{} = scope, %Game{} = game) do
    user_id = scope.user.id

    changes =
      cond do
        game.user_id == user_id and not is_nil(game.user1_left_at) ->
          %{user1_left_at: nil}

        game.user2_id == user_id and not is_nil(game.user2_left_at) ->
          %{user2_left_at: nil}

        true ->
          %{}
      end

    if changes == %{} do
      {:ok, game}
    else
      game
      |> Ecto.Changeset.change(changes)
      |> Repo.update()
      |> case do
        {:ok, game} ->
          Repo.preload(game, [:user, :user2])

        error ->
          error
      end
    end
  end

  @doc """
  Returns the user's active game (status == :active and they haven't left), if any.
  """
  def get_current_game_for_user(%Scope{} = scope) do
    user_id = scope.user.id

    from(g in Game,
      where: g.status == :active or g.status == :waiting,
      where:
        (g.user_id == ^user_id and is_nil(g.user1_left_at)) or
          (g.user2_id == ^user_id and is_nil(g.user2_left_at)),
      limit: 1,
      preload: [:user, :user2]
    )
    |> Repo.one()
  end

  def get_current_game_for_user(nil), do: nil

  def user_part_of_game?(%Scope{} = scope, %Game{} = game) do
    game.user_id == scope.user.id || game.user2_id == scope.user.id
  end

  defp user_in_other_game?(%Scope{} = scope, %Game{} = game) do
    case get_current_game_for_user(scope) do
      %Game{id: id} -> id != game.id
      nil -> false
    end
  end
end
