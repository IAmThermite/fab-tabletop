defmodule Tabletop.Games.LeaveTimer do
  @moduledoc """
  Manages delayed leave timers for game sessions.

  When a user disconnects ungracefully (browser close, network drop), a 2-minute
  timer is started. If the user reconnects before the timer fires, it is cancelled.
  If the timer fires, the user is marked as having left the game.
  """

  use GenServer

  alias Tabletop.Games

  @grace_period_ms :timer.minutes(2)

  # --- Public API ---

  def schedule_leave(game_id, user_id, scope) do
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
    game = Games.get_game!(state.scope, state.game_id)
    Games.terminate_game(state.scope, game)
    {:stop, :normal, state}
  end
end
