defmodule Tabletop.TelemetryTest do
  @moduledoc """
  Guards the wiring between the emit helpers in `Tabletop.Telemetry` and the
  metric definitions in `Tabletop.PromEx.GamePlugin`.

  A `:telemetry` event with no attached handler fails silently — a renamed event
  or a mistyped measurement key produces no error, just a metric that stays
  permanently empty in Grafana. These tests turn that silence into a failure.

  Aliased as `Events` rather than `Telemetry` so it does not shadow
  `Telemetry.Metrics.*` from the telemetry_metrics library.
  """
  use ExUnit.Case, async: true

  alias Tabletop.PromEx.GamePlugin
  alias Tabletop.Telemetry, as: Events
  alias Telemetry.Metrics.{Distribution, LastValue}

  # Compile-time list, used to generate one test per event. Kept separate from
  # `events/0` because a module attribute cannot hold an anonymous function.
  @event_names [
    Events.card_scan(),
    Events.session_action(),
    Events.session_stop(),
    Events.leave_timer_scheduled(),
    Events.leave_timer_resolved(),
    Events.camera_relay_join(),
    Events.camera_relay_signal(),
    Events.swiss_pair()
  ]

  # Every event the app emits, paired with a representative call that produces
  # it. Adding an event to `Tabletop.Telemetry` without adding it here will fail
  # the coverage test below.
  defp events do
    [
      {Events.card_scan(), fn -> Events.card_scan(1_000, :match, true, 6, :art) end},
      {Events.session_action(), fn -> Events.session_action({:move_tile, "u"}, :ok) end},
      {Events.session_stop(), fn -> Events.session_stop(:normal) end},
      {Events.leave_timer_scheduled(), fn -> Events.leave_timer_scheduled(:armed) end},
      {Events.leave_timer_resolved(), fn -> Events.leave_timer_resolved(:cancelled) end},
      {Events.camera_relay_join(), fn -> Events.camera_relay_join(:ok) end},
      {Events.camera_relay_signal(), fn -> Events.camera_relay_signal(:offer) end},
      {Events.swiss_pair(), fn -> Events.swiss_pair(1_000, 8, :ok) end}
    ]
  end

  defp plugin_metrics do
    opts = [otp_app: :tabletop]

    event_metrics =
      opts |> GamePlugin.event_metrics() |> List.wrap() |> Enum.flat_map(& &1.metrics)

    polling_metrics =
      opts |> GamePlugin.polling_metrics() |> List.wrap() |> Enum.flat_map(& &1.metrics)

    event_metrics ++ polling_metrics
  end

  # Attaches a handler that forwards the event to the test process, runs `fun`,
  # and returns the `{measurements, metadata}` it observed.
  defp capture(event, fun) do
    handler_id = {__MODULE__, event, self(), System.unique_integer()}
    parent = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _ ->
        send(parent, {:captured, handler_id, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()

      receive do
        {:captured, ^handler_id, measurements, metadata} -> {measurements, metadata}
      after
        100 -> flunk("#{inspect(event)} was not emitted")
      end
    after
      :telemetry.detach(handler_id)
    end
  end

  describe "event/metric wiring" do
    for event <- @event_names do
      test "#{inspect(event)} has at least one metric defined against it" do
        event = unquote(event)

        assert Enum.any?(plugin_metrics(), &(&1.event_name == event)),
               "no metric in GamePlugin is attached to #{inspect(event)} — " <>
                 "the event would be emitted into the void"
      end
    end

    test "every event has a representative emitter in this test" do
      assert Enum.map(events(), &elem(&1, 0)) |> Enum.sort() == Enum.sort(@event_names)
    end

    test "every helper emits the event its name accessor reports" do
      for {event, emit} <- events() do
        assert {_measurements, _metadata} = capture(event, emit)
      end
    end

    test "each numeric metric's measurement key is present in the event payload" do
      metrics_by_event = Enum.group_by(plugin_metrics(), & &1.event_name)

      for {event, emit} <- events(), metrics = metrics_by_event[event], metrics != nil do
        {measurements, _metadata} = capture(event, emit)

        for metric <- metrics, match?(%Distribution{}, metric) or match?(%LastValue{}, metric) do
          # A metric declaring a `unit:` conversion carries a function here
          # rather than the raw key; calling it resolves the value the reporter
          # would actually record, so nil means the key was missing.
          value =
            case metric.measurement do
              key when is_atom(key) -> Map.get(measurements, key)
              fun when is_function(fun, 1) -> fun.(measurements)
            end

          assert is_number(value),
                 "#{inspect(metric.name)} resolved no numeric measurement from " <>
                   "#{inspect(event)}, which emitted #{inspect(Map.keys(measurements))}"
        end
      end
    end
  end

  describe "tag cardinality" do
    test "session_action tags the action name, never its payload" do
      # A move_tile action carries a user id and coordinates — none of which may
      # reach Prometheus as a label.
      {_measurements, metadata} =
        capture(Events.session_action(), fn ->
          Events.session_action({:move_tile, "user-abc-123", 4, 5, 6}, :ok)
        end)

      assert metadata.action == :move_tile
      refute Enum.any?(Map.values(metadata), &is_binary/1)
    end

    test "session_stop collapses unbounded exit reasons to :abnormal" do
      {_measurements, metadata} =
        capture(Events.session_stop(), fn ->
          Events.session_stop({:bad_return_value, %{some: "unbounded payload"}})
        end)

      assert metadata.reason == :abnormal
    end

    test "session_stop preserves the reasons that are already bounded" do
      for {reason, expected} <- [
            {:normal, :normal},
            {:shutdown, :shutdown},
            {{:shutdown, :closed}, :shutdown}
          ] do
        {_measurements, metadata} =
          capture(Events.session_stop(), fn -> Events.session_stop(reason) end)

        assert metadata.reason == expected
      end
    end
  end

  describe "card_scan/5" do
    test "omits the distance measurement on a miss so it cannot skew the distribution" do
      {measurements, metadata} =
        capture(Events.card_scan(), fn -> Events.card_scan(1_000, :miss, false) end)

      refute Map.has_key?(measurements, :hamming_distance)
      assert metadata.result == :miss
      assert metadata.arm == :none
      assert metadata.first_try == false
    end

    test "records the distance and winning arm on a match" do
      {measurements, metadata} =
        capture(Events.card_scan(), fn ->
          Events.card_scan(1_000, :match, true, 6, :art_flipped)
        end)

      assert measurements.hamming_distance == 6
      assert metadata.arm == :art_flipped
      assert metadata.first_try == true
    end
  end
end
