defmodule Tabletop.Games.GameSession do
  @moduledoc """
  Authoritative in-memory state for a single active game.

  One GenServer per game_id, registered via
  `{:via, Registry, {GameSessionRegistry, game_id}}` and supervised under
  `GameSessionSupervisor`. Holds both players' state keyed by stable
  user id (`user1`/`user2`) so reconnecting clients can fetch a fresh
  snapshot and resume where they left off.

  Clients mutate state via `apply_action/3`; the GenServer applies the
  transform from `Tabletop.Fab.GameState` and broadcasts
  `{:game_update, side, delta, actor_user_id, snapshot}` on the existing
  `game_session:<game_id>` PubSub topic. The snapshot is carried in the message
  so subscribers never have to call back in for it — see `broadcast_update/4`.

  State is ephemeral — on crash the supervisor restarts with a fresh
  default and broadcasts `{:session_reset, snapshot}` so still-connected
  LiveViews can clear their stale assigns.
  """

  use GenServer, restart: :transient

  alias Tabletop.Fab.GameState

  # Rapid changes coalesce into one write this long after the last of them.
  @save_debounce_ms 1000

  # How long `terminate/2` waits for an in-flight async save before writing the
  # final snapshot itself.
  @save_wait_ms 2000

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
    GenServer.call(via(game_id), {:set_user2, user2_id})
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
    Process.flag(:trap_exit, true)

    db_state = Tabletop.Games.get_game_state(game_id) |> atomize_keys()

    state = %{
      game_id: game_id,
      user1_id: user1_id,
      user2_id: user2_id,
      user1: Map.merge(GameState.default_player(), Map.get(db_state, :user1, %{})),
      user2: Map.merge(GameState.default_player(), Map.get(db_state, :user2, %{})),
      save_timer: nil,
      save_task: nil
    }

    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{game_id}",
      {:session_reset, snapshot(state)}
    )

    {:ok, state}
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(other), do: other

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call({:apply_action, actor_user_id, action}, _from, state) do
    with {:ok, target_side} <- resolve_target_side(state, actor_user_id, action),
         player = Map.fetch!(state, target_side),
         {:ok, new_player, delta} <- dispatch(action, player) do
      new_state = Map.put(state, target_side, new_player)
      new_state = schedule_save(new_state)
      broadcast_update(new_state, target_side, delta, actor_user_id)
      Tabletop.Telemetry.session_action(action, :ok)
      {:reply, :ok, new_state}
    else
      {:error, _} = error ->
        Tabletop.Telemetry.session_action(action, :error)
        {:reply, error, state}
    end
  end

  def handle_call({:set_user2, user2_id}, _from, state) do
    {:reply, :ok, %{state | user2_id: user2_id}}
  end

  @impl true
  def handle_info(:save_state, %{save_task: nil} = state) do
    # The write runs in a supervised Task, not here: in production it crosses
    # the private network to a separate Postgres app, and doing it inline blocks
    # every `apply_action`/`get_state` for this game until it lands — head-of-line
    # latency on exactly the path a player's click travels.
    {:noreply, %{start_save(state) | save_timer: nil}}
  end

  # A save is still in flight. Starting a second one would race it, and since
  # both are `on_conflict: :replace_all` full-snapshot writes the older one
  # could land last and roll the persisted state backwards. Re-arm the timer
  # instead so the newest snapshot is written once this one finishes.
  def handle_info(:save_state, state) do
    {:noreply, schedule_save(%{state | save_timer: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{save_task: ref} = state) do
    {:noreply, %{state | save_task: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # An abnormal reason means this session's in-memory state was lost and
    # connected LiveViews will be reset by the restarted session's
    # `{:session_reset, _}` broadcast — worth alerting on.
    Tabletop.Telemetry.session_stop(reason)
    # This snapshot is the newest one, so it has to be the last write. Wait out
    # any async save rather than racing it — see the `:save_state` clauses.
    await_save(state)
    Tabletop.Games.update_game_state(state.game_id, snapshot(state))
  end

  defp await_save(%{save_task: nil}), do: :ok

  defp await_save(%{save_task: ref}) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @save_wait_ms -> :ok
    end
  end

  defp start_save(state) do
    snapshot = snapshot(state)

    case Task.Supervisor.start_child(Tabletop.TaskSupervisor, fn ->
           Tabletop.Games.update_game_state(state.game_id, snapshot)
         end) do
      {:ok, pid} -> %{state | save_task: Process.monitor(pid)}
      _error -> state
    end
  end

  # Debounced save: only schedule if no timer is already pending
  # This prevents multiple sequential writes by coalescing rapid changes
  # into a single database write after 1 second of inactivity
  defp schedule_save(%{save_timer: nil} = state) do
    timer = Process.send_after(self(), :save_state, @save_debounce_ms)
    %{state | save_timer: timer}
  end

  # If a save is already scheduled (existing `save_timer`), do nothing (debounce in action)
  defp schedule_save(state), do: state

  defp snapshot(state), do: %{user1: state.user1, user2: state.user2}

  # `move_tile` explicitly names the owner of the tile being moved — either
  # player can drag their own or their opponent's tiles.
  defp resolve_target_side(state, _actor, {:move_tile, target_user_id, _, _, _}) do
    side_for(state, target_user_id)
  end

  # Proxy tokens work the same way: the action names the player the token sits
  # *on*, so either player can hand one to the other (Mark, Frostbite) or take
  # one for themselves, and either player can clear it again.
  @targeted_actions [:add_proxy_token, :remove_proxy_token, :toggle_proxy_token]

  defp resolve_target_side(state, _actor, {action, target_user_id, _name})
       when action in @targeted_actions do
    side_for(state, target_user_id)
  end

  # Everything else targets the actor's own side.
  defp resolve_target_side(state, actor_user_id, _action) do
    side_for(state, actor_user_id)
  end

  defp side_for(%{user1_id: id}, id), do: {:ok, :user1}
  defp side_for(%{user2_id: id}, id) when not is_nil(id), do: {:ok, :user2}
  defp side_for(_, _), do: {:error, :unknown_user}

  # The action → transform mapping lives in `GameState.transform/2` so it is
  # shared with the camera-setup preview; here we just resolve the target side
  # (above) and apply.
  defp dispatch(action, player), do: GameState.transform(player, action)

  # The snapshot rides along with the delta. Subscribers used to answer a
  # broadcast with `get_state/1`, which put two synchronous calls back into this
  # GenServer on every action (one per connected LiveView) — and those calls
  # queue behind whatever else the process is doing. Sending the state we
  # already computed removes that round trip, and pairs each delta with the
  # exact state it produced instead of whatever is current by the time the
  # subscriber gets around to asking.
  defp broadcast_update(state, target_side, delta, actor_user_id) do
    Phoenix.PubSub.broadcast(
      Tabletop.PubSub,
      "game_session:#{state.game_id}",
      {:game_update, target_side, delta, actor_user_id, snapshot(state)}
    )
  end
end
