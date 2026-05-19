defmodule Tabletop.Games.LeaveTimer do
  @moduledoc """
  Manages delayed leave timers for game sessions.

  When a user disconnects ungracefully (browser close, network drop), a 5-minute
  timer is started. If the user reconnects before the timer fires, it is cancelled.
  If the timer fires, the user is marked as having left the game.

  Cancelling the timer on reconnect is not enough on its own: when a user
  refreshes the page, the reconnecting LiveView can mount (and call
  `cancel_leave/2`) *before* the old LiveView's `terminate/2` runs and calls
  `schedule_leave/3`, leaving an orphaned timer. To guard against this, every
  connected LiveView registers itself via `track_connection/2`, and the leave
  is only scheduled/executed when no live connection for that user remains.
  """

  use GenServer

  alias Tabletop.Games

  @grace_period_ms :timer.minutes(5)
  @connection_registry Tabletop.Games.GameConnectionRegistry

  # --- Public API ---

  @doc """
  Registers the calling process (a connected LiveView) as an active
  connection for `{game_id, user_id}`. The registration is automatically
  removed by the Registry when the process exits.
  """
  def track_connection(game_id, user_id) do
    Registry.register(@connection_registry, {game_id, user_id}, nil)
  end

  def schedule_leave(game_id, user_id, scope) do
    # On a page refresh the reconnecting LiveView can mount before the old
    # one's `terminate/2` runs. If the user already has another live
    # connection, there is nothing to schedule.
    if user_connected?(game_id, user_id) do
      :ok
    else
      key = {game_id, user_id}

      case DynamicSupervisor.start_child(
             Tabletop.Games.LeaveTimerSupervisor,
             {__MODULE__, {key, scope}}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        error -> error
      end
    end
  end

  def cancel_leave(game_id, user_id) do
    key = {game_id, user_id}

    case Registry.lookup(Tabletop.Games.LeaveTimerRegistry, key) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  # --- GenServer callbacks ---

  def start_link({key, scope}) do
    GenServer.start_link(__MODULE__, {key, scope},
      name: {:via, Registry, {Tabletop.Games.LeaveTimerRegistry, key}}
    )
  end

  @impl true
  def init({{game_id, user_id}, scope}) do
    timer_ref = Process.send_after(self(), :execute_leave, @grace_period_ms)

    {:ok,
     %{
       game_id: game_id,
       user_id: user_id,
       scope: scope,
       timer_ref: timer_ref
     }}
  end

  @impl true
  def handle_info(:execute_leave, state) do
    # Safety net for the mount-before-terminate race: if the user has a live
    # connection by the time the timer fires, they reconnected (e.g. a page
    # refresh) and the game should not be ended.
    if user_connected?(state.game_id, state.user_id) do
      {:stop, :normal, state}
    else
      game = Games.get_game!(state.scope, state.game_id)
      Games.terminate_game(state.scope, game)
      {:stop, :normal, state}
    end
  end

  # --- Internal ---

  # True if any process *other than the caller* is registered as a live
  # connection for this user/game. The caller is excluded so that the
  # disconnecting LiveView (still registered while its `terminate/2` runs)
  # does not count as itself being connected.
  defp user_connected?(game_id, user_id) do
    @connection_registry
    |> Registry.lookup({game_id, user_id})
    |> Enum.any?(fn {pid, _} -> pid != self() end)
  end
end
