defmodule Tabletop.Games.GameSession do
  @moduledoc """
  Authoritative in-memory state for a single active game.

  One GenServer per game_id, registered via
  `{:via, Registry, {GameSessionRegistry, game_id}}` and supervised under
  `GameSessionSupervisor`. Holds both players' state keyed by stable
  user id (`user1`/`user2`) so reconnecting clients can fetch a fresh
  snapshot and resume where they left off.

  Clients mutate state via `apply_action/3`; the GenServer applies the
  transform from `Tabletop.Fab.GameState` and broadcasts the resulting
  delta on the existing `game_session:<game_id>` PubSub topic.

  State is ephemeral — on crash the supervisor restarts with a fresh
  default and broadcasts `{:session_reset, snapshot}` so still-connected
  LiveViews can clear their stale assigns.
  """

  use GenServer, restart: :transient

  alias Tabletop.Fab.GameState

  # --- Public API ---

  def ensure_started(%{id: game_id, user_id: user1_id, user2_id: user2_id}) do
    case DynamicSupervisor.start_child(
           Tabletop.Games.GameSessionSupervisor,
           {__MODULE__, %{game_id: game_id, user1_id: user1_id, user2_id: user2_id}}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      error -> error
    end
  end

  def get_state(game_id) do
    GenServer.call(via(game_id), :get_state)
  end

  def apply_action(game_id, actor_user_id, action) do
    GenServer.call(via(game_id), {:apply_action, actor_user_id, action})
  end

  def set_user2(game_id, user2_id) do
    GenServer.cast(via(game_id), {:set_user2, user2_id})
  end

  def stop(game_id) do
    case Registry.lookup(Tabletop.Games.GameSessionRegistry, game_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  # --- GenServer ---

  def start_link(%{game_id: game_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via(game_id))
  end

  defp via(game_id),
    do: {:via, Registry, {Tabletop.Games.GameSessionRegistry, game_id}}

  @impl true
  def init(%{game_id: game_id, user1_id: user1_id, user2_id: user2_id}) do
    state = %{
      game_id: game_id,
      user1_id: user1_id,
      user2_id: user2_id,
      user1: GameState.default_player(),
      user2: GameState.default_player()
    }

    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{game_id}",
      {:session_reset, snapshot(state)}
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call({:apply_action, actor_user_id, action}, _from, state) do
    with {:ok, target_side} <- resolve_target_side(state, actor_user_id, action),
         player = Map.fetch!(state, target_side),
         {:ok, new_player, delta} <- dispatch(action, player) do
      new_state = Map.put(state, target_side, new_player)
      broadcast_update(state.game_id, target_side, delta, actor_user_id)
      {:reply, :ok, new_state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:set_user2, user2_id}, state) do
    {:noreply, %{state | user2_id: user2_id}}
  end

  defp snapshot(state), do: %{user1: state.user1, user2: state.user2}

  # `move_tile` explicitly names the owner of the tile being moved — either
  # player can drag their own or their opponent's tiles.
  defp resolve_target_side(state, _actor, {:move_tile, target_user_id, _, _, _}) do
    side_for(state, target_user_id)
  end

  # Everything else targets the actor's own side.
  defp resolve_target_side(state, actor_user_id, _action) do
    side_for(state, actor_user_id)
  end

  defp side_for(%{user1_id: id}, id), do: {:ok, :user1}
  defp side_for(%{user2_id: id}, id) when not is_nil(id), do: {:ok, :user2}
  defp side_for(_, _), do: {:error, :unknown_user}

  defp dispatch({:move_tile, _target, tile_id, x, y}, player),
    do: GameState.move_tile(player, tile_id, x, y)

  defp dispatch({:toggle_damage, type}, player), do: GameState.toggle_damage(player, type)

  defp dispatch({:change_damage, type, delta}, player),
    do: GameState.change_damage(player, type, delta)

  defp dispatch({:toggle_goagain}, player), do: GameState.toggle_goagain(player)
  defp dispatch({:toggle_effect, name}, player), do: GameState.toggle_effect(player, name)
  defp dispatch({:change_life, delta}, player), do: GameState.change_life(player, delta)
  defp dispatch({:reset_chain}, player), do: GameState.reset_chain(player)
  defp dispatch(_, _), do: {:error, :unknown_action}

  defp broadcast_update(game_id, target_side, delta, actor_user_id) do
    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{game_id}",
      {:game_update, target_side, delta, actor_user_id}
    )
  end
end
