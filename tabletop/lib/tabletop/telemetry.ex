defmodule Tabletop.Telemetry do
  @moduledoc """
  Canonical names for the app's own `:telemetry` events, plus the emit helpers
  that normalise their metadata.

  Metric *definitions* live in `Tabletop.PromEx.GamePlugin`; the emit calls live
  next to the code they measure. Both sides reference the names here so a rename
  can't silently detach a metric from its event — a `:telemetry` event with no
  attached handler fails silently, which is exactly the bug this module exists
  to prevent.

  ## Tag cardinality

  Every tag below is drawn from a bounded set. Prometheus creates one time
  series per label combination, so never tag with a `game_id`, `user_id`, card
  name, or anything else unbounded — Fly's scraper drops high-cardinality
  metrics outright.
  """

  # --- Event names ---

  @doc "Periodic sample of live game activity. Emitted by the PromEx poller."
  def census, do: [:tabletop, :census]

  @doc "A card scan resolved (or failed to resolve) against the pHash matcher."
  def card_scan, do: [:tabletop, :card_scan, :stop]

  @doc "An action was applied to a `Tabletop.Games.GameSession`."
  def session_action, do: [:tabletop, :game_session, :action]

  @doc "A `Tabletop.Games.GameSession` terminated."
  def session_stop, do: [:tabletop, :game_session, :stop]

  @doc "A leave timer was armed for a disconnected user."
  def leave_timer_scheduled, do: [:tabletop, :leave_timer, :scheduled]

  @doc "An armed leave timer reached an outcome."
  def leave_timer_resolved, do: [:tabletop, :leave_timer, :resolved]

  @doc "A camera relay channel join was accepted or rejected."
  def camera_relay_join, do: [:tabletop, :camera_relay, :join]

  @doc "A WebRTC signalling message was relayed between desktop and phone."
  def camera_relay_signal, do: [:tabletop, :camera_relay, :signal]

  @doc "A round of Swiss pairing completed."
  def swiss_pair, do: [:tabletop, :tournaments, :swiss_pair]

  # --- Emit helpers ---

  @doc """
  Records the outcome of a card scan.

  `hamming` is the distance of the winning arm and `arm` the arm that won
  (`:art`, `:art_flipped` or `:full`); both are `nil` on a miss, in which case
  the distance measurement is omitted entirely so it never skews the
  distribution.
  """
  def card_scan(duration, result, first_try?, hamming \\ nil, arm \\ nil) do
    measurements =
      case hamming do
        nil -> %{duration: duration}
        distance -> %{duration: duration, hamming_distance: distance}
      end

    :telemetry.execute(card_scan(), measurements, %{
      result: result,
      first_try: first_try?,
      arm: arm || :none
    })
  end

  @doc """
  Records an action applied to a game session.

  Only the action *name* is tagged — the payload (tile ids, coordinates, user
  ids) is unbounded and must never become a label.
  """
  def session_action(action, result) do
    :telemetry.execute(session_action(), %{count: 1}, %{
      action: action_name(action),
      result: result
    })
  end

  defp action_name(action) when is_atom(action), do: action
  defp action_name(action) when is_tuple(action), do: elem(action, 0)
  defp action_name(_), do: :unknown

  @doc """
  Records a game session termination.

  Anything other than `:normal` or `:shutdown` is reported as `:abnormal` —
  raw exit reasons are unbounded and would explode label cardinality.
  """
  def session_stop(reason) do
    :telemetry.execute(session_stop(), %{count: 1}, %{reason: stop_reason(reason)})
  end

  defp stop_reason(:normal), do: :normal
  defp stop_reason(:shutdown), do: :shutdown
  defp stop_reason({:shutdown, _}), do: :shutdown
  defp stop_reason(_), do: :abnormal

  @doc """
  Records an attempt to arm a leave timer.

  `result` is `:armed` when a timer was actually started, or one of
  `:already_reconnected` / `:already_armed` / `:error` when it was not. A high
  `:already_reconnected` share means most disconnects are page refreshes rather
  than departures.
  """
  def leave_timer_scheduled(result) do
    :telemetry.execute(leave_timer_scheduled(), %{count: 1}, %{result: result})
  end

  @doc """
  Records how an armed leave timer ended: `:cancelled` (user reconnected before
  it fired), `:reconnected` (reconnected in the window between firing and the
  connection check), or `:game_terminated` (grace period genuinely expired).
  """
  def leave_timer_resolved(outcome) do
    :telemetry.execute(leave_timer_resolved(), %{count: 1}, %{outcome: outcome})
  end

  @doc "Records a camera relay channel join, accepted (`:ok`) or rejected."
  def camera_relay_join(result) do
    :telemetry.execute(camera_relay_join(), %{count: 1}, %{result: result})
  end

  @doc """
  Records a relayed WebRTC signalling message. `signal` is the message kind
  (`:offer`, `:answer`, `:ice_candidate`, `:peer_joined`, `:peer_left`) —
  offers materially outnumbering answers means handshakes are not completing.
  """
  def camera_relay_signal(signal) do
    :telemetry.execute(camera_relay_signal(), %{count: 1}, %{signal: signal})
  end

  @doc """
  Records a completed round of Swiss pairing.

  `player_count` is the active field size, which is the main driver of the DFS
  backtracking cost in `Tabletop.Tournaments.Pairing.Swiss`.
  """
  def swiss_pair(duration, player_count, result) do
    :telemetry.execute(
      swiss_pair(),
      %{duration: duration, player_count: player_count},
      %{result: result}
    )
  end
end
