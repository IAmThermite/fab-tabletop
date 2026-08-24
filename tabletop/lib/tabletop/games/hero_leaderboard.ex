defmodule Tabletop.Games.HeroLeaderboard do
  @moduledoc """
  Caches the lobby's popular-heroes leaderboard.

  `Tabletop.Games.activity_stats/0` runs in *every* connected lobby LiveView on
  *every* game broadcast, and the leaderboard is by far its most expensive part:
  it aggregates a rolling 7-day window of games plus tournament registrations,
  where the rest of the snapshot only touches games that are open or in progress
  right now. A 7-day ranking does not meaningfully change between two lobby
  events, so this server owns one copy, refreshes it on a slow timer, and turns
  every reader into an ETS lookup.

  Readers never block on this process — `get/0` reads the table directly and
  falls back to computing inline when the cache is cold: before the first
  refresh, after a failed one, or when the server isn't running at all (the test
  suite and `mix run` scripts). That fallback keeps the numbers correct at the
  cost of the scan, so a missing server degrades to the old behaviour rather
  than to a wrong or empty leaderboard.

  The refresh interval comes from the `:hero_leaderboard_refresh_ms` app env.
  Setting it to `nil` disables refreshing entirely, which is what the test suite
  does: a background process holding its own connection is invisible to the Ecto
  sandbox, and a cache populated by one async test would leak into every other.
  """

  use GenServer

  require Logger

  alias Tabletop.Games

  @table __MODULE__
  @key :popular_heroes

  # Days of activity the leaderboard covers. Also the effective staleness bound
  # of the whole aggregate, which is why a 30-minute refresh is plenty.
  @window_days 7
  @default_refresh_ms :timer.minutes(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The current leaderboard, as `%{format => [{hero_slug, count}]}`.

  Reads the cache directly (no call into this process). Computes inline when the
  cache is cold — see the module doc.
  """
  def get do
    case cached() do
      {:ok, leaderboard} -> leaderboard
      :error -> compute()
    end
  end

  @doc """
  Recomputes the leaderboard now and returns it, rather than waiting for the
  next tick. Runs in the server process, so callers under the Ecto sandbox must
  allow it on their connection first.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc """
  Drops the cached leaderboard so the next `get/0` recomputes.

  Only the test suite needs this, to stop a cache it populated on purpose from
  leaking into other tests. In production the refresh timer is the only writer.
  """
  def invalidate do
    GenServer.call(__MODULE__, :invalidate)
  end

  @doc """
  Days of recent activity the leaderboard covers.
  """
  def window_days, do: @window_days

  @impl true
  def init(_opts) do
    # Owned by this process, so a crash drops the cache and the next `get/0`
    # falls back to computing inline until the restarted server refills it.
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    if refresh_interval() do
      {:ok, %{}, {:continue, :refresh}}
    else
      {:ok, %{}}
    end
  end

  @impl true
  def handle_continue(:refresh, state) do
    refresh_cache()
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh_cache()
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {:reply, refresh_cache(), state}
  end

  @impl true
  def handle_call(:invalidate, _from, state) do
    :ets.delete(@table, @key)
    {:reply, :ok, state}
  end

  # Recomputes and stores the leaderboard, returning it. A failing refresh must
  # not take this server (and with it the cached ranking) down — the database
  # being briefly unreachable should leave the lobby serving the previous
  # ranking until the next tick, not crash it.
  defp refresh_cache do
    leaderboard = compute()
    :ets.insert(@table, {@key, leaderboard})
    leaderboard
  rescue
    error ->
      Logger.warning("HeroLeaderboard refresh failed: #{Exception.message(error)}")

      case cached() do
        {:ok, leaderboard} -> leaderboard
        :error -> %{}
      end
  end

  defp cached do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{@key, leaderboard}] <- :ets.lookup(tid, @key) do
      {:ok, leaderboard}
    else
      _ -> :error
    end
  end

  defp compute do
    DateTime.utc_now()
    |> DateTime.add(-@window_days * 24 * 60 * 60, :second)
    |> Games.popular_heroes_by_format()
  end

  defp schedule_refresh do
    if ms = refresh_interval(), do: Process.send_after(self(), :refresh, ms)
  end

  defp refresh_interval do
    Application.get_env(:tabletop, :hero_leaderboard_refresh_ms, @default_refresh_ms)
  end
end
