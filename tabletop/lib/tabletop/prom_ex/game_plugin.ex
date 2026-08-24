defmodule Tabletop.PromEx.GamePlugin do
  @moduledoc """
  App-specific metrics — the signals the stock Phoenix/Ecto/BEAM dashboards
  cannot provide.

  Five groups, each answering a question that is currently unanswerable in
  production:

    * **Card scanner** — how often a scan resolves to a card, the Hamming
      distance of the winning arm, and whether the scanner needed its
      expanded-region retry. Together these say whether the thresholds in
      `Tabletop.Cards` (`@art_threshold` / `@full_threshold`) are right against
      real sleeves and lighting rather than against fixtures.
    * **Game sessions** — how many `Tabletop.Games.GameSession` GenServers are
      alive, action throughput by action name, and how sessions stop. A session
      crash silently wipes in-memory game state, so the abnormal-stop counter is
      the one worth alerting on.
    * **Leave timers** — scheduled vs. cancelled vs. fired. The ratio says how
      much of the 5-minute grace period is actually load-bearing, and how often
      the mount-before-terminate race is being caught.
    * **Camera relay** — join outcomes and signalling volume for the
      phone-as-webcam flow, which has the most moving parts and the least
      visibility.
    * **Swiss pairing** — wall-clock of `Swiss.pair/3`, which does DFS
      backtracking for rematch avoidance and is the code most likely to degrade
      on a large field.

  Metric definitions live here; the `:telemetry.execute/3` calls that feed them
  live next to the code they measure. Event names are documented on
  `Tabletop.Telemetry`.
  """

  use PromEx.Plugin

  alias Tabletop.Telemetry, as: Events

  @impl true
  def event_metrics(opts) do
    metric_prefix = metric_prefix(opts)

    [
      card_scan_metrics(metric_prefix),
      game_session_metrics(metric_prefix),
      leave_timer_metrics(metric_prefix),
      camera_relay_metrics(metric_prefix),
      tournament_metrics(metric_prefix)
    ]
  end

  @impl true
  def polling_metrics(opts) do
    metric_prefix = metric_prefix(opts)
    poll_rate = Keyword.get(opts, :poll_rate, 10_000)

    Polling.build(
      :tabletop_runtime_census_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_census, []},
      [
        last_value(
          metric_prefix ++ [:sessions, :active],
          event_name: Events.census(),
          measurement: :active_sessions,
          description: "GameSession GenServers currently alive."
        ),
        last_value(
          metric_prefix ++ [:leave_timers, :armed],
          event_name: Events.census(),
          measurement: :armed_leave_timers,
          description: "Leave timers armed — users inside the 5 minute grace period."
        ),
        last_value(
          metric_prefix ++ [:connections, :tracked],
          event_name: Events.census(),
          measurement: :tracked_connections,
          description: "Connected game LiveViews tracked in GameConnectionRegistry."
        )
      ]
    )
  end

  @doc """
  Samples the three registries that describe live game activity. Invoked by
  PromEx's poller; not meant to be called directly.
  """
  def execute_census do
    :telemetry.execute(
      Events.census(),
      %{
        active_sessions: registry_count(Tabletop.Games.GameSessionRegistry),
        armed_leave_timers: registry_count(Tabletop.Games.LeaveTimerRegistry),
        tracked_connections: registry_count(Tabletop.Games.GameConnectionRegistry)
      },
      %{}
    )
  end

  # The registries are started by Tabletop.Application, but the poller can fire
  # during boot or in tests where they are absent.
  defp registry_count(registry) do
    Registry.count(registry)
  rescue
    ArgumentError -> 0
  end

  defp metric_prefix(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(otp_app, :game))
  end

  # --- Card scanner ---

  defp card_scan_metrics(metric_prefix) do
    Event.build(:tabletop_card_scan_event_metrics, [
      counter(
        metric_prefix ++ [:card_scan, :total],
        event_name: Events.card_scan(),
        description: "Card scans resolved by the pHash matcher.",
        tags: [:result, :first_try]
      ),
      distribution(
        metric_prefix ++ [:card_scan, :hamming_distance],
        event_name: Events.card_scan(),
        measurement: :hamming_distance,
        description:
          "Hamming distance of the winning pHash arm. Only recorded on a match — a distribution " <>
            "creeping toward the threshold means the thresholds need revisiting.",
        # Straddles both thresholds: @full_threshold 8 and @art_threshold 15.
        reporter_options: [buckets: [1, 2, 3, 4, 6, 8, 10, 12, 14, 15]],
        tags: [:arm]
      ),
      distribution(
        metric_prefix ++ [:card_scan, :duration, :milliseconds],
        event_name: Events.card_scan(),
        measurement: :duration,
        description: "Time spent in the pHash similarity query.",
        reporter_options: [buckets: [5, 10, 25, 50, 100, 250, 500, 1_000]],
        unit: {:native, :millisecond},
        tags: [:result]
      )
    ])
  end

  # --- Game sessions ---

  defp game_session_metrics(metric_prefix) do
    Event.build(:tabletop_game_session_event_metrics, [
      counter(
        metric_prefix ++ [:session, :actions, :total],
        event_name: Events.session_action(),
        description: "Actions applied to a GameSession, by action name and outcome.",
        tags: [:action, :result]
      ),
      counter(
        metric_prefix ++ [:session, :stops, :total],
        event_name: Events.session_stop(),
        description:
          "GameSession terminations. An `abnormal` stop means in-memory game state was lost " <>
            "and connected clients were reset.",
        tags: [:reason]
      )
    ])
  end

  # --- Leave timers ---

  defp leave_timer_metrics(metric_prefix) do
    Event.build(:tabletop_leave_timer_event_metrics, [
      counter(
        metric_prefix ++ [:leave_timer, :scheduled, :total],
        event_name: Events.leave_timer_scheduled(),
        description: "Leave timers armed after a user disconnected.",
        tags: [:result]
      ),
      counter(
        metric_prefix ++ [:leave_timer, :resolved, :total],
        event_name: Events.leave_timer_resolved(),
        description:
          "How armed leave timers ended: `cancelled` (reconnected in time), `reconnected` " <>
            "(raced the timer at fire time), or `game_terminated` (grace period expired).",
        tags: [:outcome]
      )
    ])
  end

  # --- Camera relay ---

  defp camera_relay_metrics(metric_prefix) do
    Event.build(:tabletop_camera_relay_event_metrics, [
      counter(
        metric_prefix ++ [:camera_relay, :joins, :total],
        event_name: Events.camera_relay_join(),
        description: "Camera relay channel joins, by outcome.",
        tags: [:result]
      ),
      counter(
        metric_prefix ++ [:camera_relay, :signals, :total],
        event_name: Events.camera_relay_signal(),
        description:
          "WebRTC signalling messages relayed between a player's desktop and phone. " <>
            "Offers without matching answers indicate handshakes that never completed.",
        tags: [:signal]
      )
    ])
  end

  # --- Tournaments ---

  defp tournament_metrics(metric_prefix) do
    Event.build(:tabletop_tournament_event_metrics, [
      distribution(
        metric_prefix ++ [:swiss_pair, :duration, :milliseconds],
        event_name: Events.swiss_pair(),
        measurement: :duration,
        description: "Wall-clock of a single Swiss pairing round, including DFS backtracking.",
        reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1_000, 5_000]],
        unit: {:native, :millisecond},
        tags: [:result]
      ),
      distribution(
        metric_prefix ++ [:swiss_pair, :field_size],
        event_name: Events.swiss_pair(),
        measurement: :player_count,
        description: "Active players fed into the pairing engine, for correlating with duration.",
        reporter_options: [buckets: [4, 8, 16, 32, 64, 128, 256]],
        tags: [:result]
      )
    ])
  end
end
