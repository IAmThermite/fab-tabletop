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
        where: g.private == false,
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
        where: g.private == false,
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
  Returns an at-a-glance snapshot of lobby activity for the live-activity panel.

  The returned map has:

    * `:open_by_format` — `%{format => count}` of public games waiting for an
      opponent (reservation-aware; mirrors `list_joinable_games/2`, but global
      rather than scoped to a single user)
    * `:open_total` — sum of `:open_by_format`
    * `:active_games` — number of games currently in progress (`status == :active`)
    * `:active_players` — players currently seated in those active games (i.e.
      who have not left); a user can only be in one game at a time, so this is a
      distinct head-count
    * `:popular_heroes` — `%{format => [{hero_slug, count}]}`, the most-chosen
      heroes across games created in the last `days` days (default 7), most
      popular first, capped per format

  Cheap enough to recompute on every lobby broadcast.
  """
  def activity_stats(days \\ 7) do
    open_by_format = open_games_by_format()
    active = active_game_stats()

    %{
      open_by_format: open_by_format,
      open_total: open_by_format |> Map.values() |> Enum.sum(),
      active_games: active.games,
      active_players: active.players,
      popular_heroes: popular_heroes_by_format(days)
    }
  end

  # Counts public games still waiting for an opponent, grouped by format. Skips
  # games that are currently reserved by a (non-expired) joiner, matching the
  # joinable-list semantics. Formats with no open games are simply absent.
  defp open_games_by_format do
    now = DateTime.utc_now()

    from(g in Game,
      where: g.status == :waiting,
      where: g.private == false,
      where: is_nil(g.user2_id),
      where: is_nil(g.joining_user_id) or g.joining_expires_at < ^now,
      group_by: g.format,
      select: {g.format, count(g.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Active games and the number of players actually seated in them. We pull the
  # left-at/opponent columns for the (small) set of active games and tally alive
  # seats in Elixir, since "still present" is a per-seat condition.
  defp active_game_stats do
    seats =
      from(g in Game,
        where: g.status == :active,
        select: {g.user1_left_at, g.user2_id, g.user2_left_at}
      )
      |> Repo.all()

    players =
      Enum.reduce(seats, 0, fn {user1_left_at, user2_id, user2_left_at}, acc ->
        acc +
          if(is_nil(user1_left_at), do: 1, else: 0) +
          if(not is_nil(user2_id) and is_nil(user2_left_at), do: 1, else: 0)
      end)

    %{games: length(seats), players: players}
  end

  @hero_leaderboard_limit 3

  # Top heroes chosen per format across games created within the window. Counts
  # every created game (any status) that names a known-or-not hero; blank heroes
  # are excluded. Returns at most `@hero_leaderboard_limit` heroes per format.
  defp popular_heroes_by_format(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    from(g in Game,
      where: g.inserted_at >= ^cutoff,
      where: not is_nil(g.hero) and g.hero != "",
      group_by: [g.format, g.hero],
      select: {g.format, g.hero, count(g.id)}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {format, _hero, _count} -> format end,
      fn {_format, hero, count} -> {hero, count} end
    )
    |> Map.new(fn {format, heroes} ->
      top =
        heroes
        |> Enum.sort_by(fn {_hero, count} -> count end, :desc)
        |> Enum.take(@hero_leaderboard_limit)

      {format, top}
    end)
  end

  @doc """
  Gets a single game the scoped user is a participant in (creator or opponent).

  Raises `Ecto.NoResultsError` if the game does not exist OR if the scoped user
  is not a participant. Authorization is intentionally folded into the lookup so
  callers cannot accidentally leak metadata about games the user doesn't belong
  to (see `fetch_game/1` for the unscoped variant used by the pre-join flow).

  ## Examples

      iex> get_game!(scope, 123)
      %Game{}

      iex> get_game!(scope, 456)
      ** (Ecto.NoResultsError)

  """
  def get_game!(%Scope{} = scope, id) do
    case get_game(scope, id) do
      {:ok, game} -> game
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Game
    end
  end

  @doc """
  Gets a single game the scoped user is a participant in.

  Returns `{:ok, %Game{}}` or `{:error, :not_found}`. Same authorization rules
  as `get_game!/2`.
  """
  def get_game(%Scope{} = scope, id) do
    case Repo.get(Game, id) do
      nil ->
        {:error, :not_found}

      %Game{} = game ->
        game = Repo.preload(game, [:user, :user2])

        if user_part_of_game?(scope, game) do
          {:ok, game}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Fetches a game by id without any participant scoping. Used by the pre-join
  flow where the requesting user is not yet a participant but has been given
  the game's UUID as the invitation token.

  Returns `{:ok, %Game{}}` or `{:error, :not_found}`.
  """
  def fetch_game(id) do
    case Repo.get(Game, id) do
      nil -> {:error, :not_found}
      %Game{} = game -> {:ok, Repo.preload(game, [:user, :user2])}
    end
  end

  @doc """
  Looks up a game by its UUID for the "join by code" flow.

  Returns `{:ok, game}` if the id is a valid UUID and the game is in :waiting
  status, otherwise `{:error, :not_found}`. Does not enforce the public/private
  filter — possession of the UUID is the access token.
  """
  def get_joinable_game_by_code(code) when is_binary(code) do
    case Ecto.UUID.cast(String.trim(code)) do
      {:ok, id} ->
        case Repo.get_by(Game, id: id, status: :waiting) do
          nil -> {:error, :not_found}
          %Game{} = game -> {:ok, Repo.preload(game, [:user, :user2])}
        end

      :error ->
        {:error, :invalid_code}
    end
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
      where:
        is_nil(g.joining_user_id) or g.joining_expires_at < ^now or
          g.joining_user_id == ^user_id
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

  @doc """
  Returns the most recent game *created* by the scoped user (any status), or
  `nil` if they have never created one. Powers the lobby's "quick match" button,
  which re-seeds the create form from a previous game's settings. Only games the
  user created are considered, since the hero/decklist on a joined game belong to
  the other player.
  """
  def get_last_created_game(%Scope{user: user}) do
    from(g in Game,
      where: g.user_id == ^user.id,
      order_by: [desc: g.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  def get_last_created_game(nil), do: nil

  def user_part_of_game?(%Scope{} = scope, %Game{} = game) do
    game.user_id == scope.user.id || game.user2_id == scope.user.id
  end

  defp user_in_other_game?(%Scope{} = scope, %Game{} = game) do
    case get_current_game_for_user(scope) do
      %Game{id: id} -> id != game.id
      nil -> false
    end
  end

  @doc """
  Updates or creates the state for a given game using an upsert.
  """
  def update_game_state(game_id, state_map) do
    %Tabletop.Games.GameState{
      game_id: game_id,
      state: state_map
    }
    |> Repo.insert!(
      on_conflict: :replace_all,
      conflict_target: :game_id
    )
  rescue
    _ -> :error
  end

  @doc """
  Gets the state for a given game, returning an empty map if not found.
  """
  def get_game_state(game_id) do
    case Repo.get(Tabletop.Games.GameState, game_id) do
      nil -> %{}
      record -> record.state
    end
  rescue
    _ -> %{}
  end
end
