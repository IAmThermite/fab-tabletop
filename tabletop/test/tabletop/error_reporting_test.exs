defmodule Tabletop.ErrorReportingTest do
  @moduledoc """
  Error reporting is silent when it breaks — a misconfigured handler looks
  exactly like an app with no errors. These tests assert the wiring exists, so
  a future refactor that drops the handler or the LiveView hook fails loudly.
  """
  use ExUnit.Case, async: false

  require Logger

  describe "logger handler" do
    test "is attached, so crashes reach Sentry without any per-callsite code" do
      handler_ids = :logger.get_handler_ids()

      assert :sentry_handler in handler_ids,
             "Sentry.LoggerHandler is not attached — crashes would be reported nowhere. " <>
               "Attached handlers: #{inspect(handler_ids)}"
    end

    test "is rate limited, so a crash loop cannot burn the event quota" do
      {:ok, config} = :logger.get_handler_config(:sentry_handler)

      assert %{config: %{rate_limiting: rate_limiting}} = config
      assert Keyword.fetch!(rate_limiting, :max_events) > 0
      assert Keyword.fetch!(rate_limiting, :interval) > 0
    end

    test "captures Logger.error and above, not just process crashes" do
      {:ok, config} = :logger.get_handler_config(:sentry_handler)

      # `:capture_level`, not `:level` — the latter is a deprecated alias that
      # normalises to this, so asserting on `:level` silently never matches.
      assert %{config: %{capture_log_messages: true, capture_level: :error}} = config
    end

    test "excludes webserver domains, so Phoenix errors are not reported twice" do
      {:ok, config} = :logger.get_handler_config(:sentry_handler)

      assert %{config: %{capture_excluded_domains: domains}} = config
      assert :bandit in domains
    end
  end

  describe "capture" do
    setup :start_collecting_sentry_reports

    test "an exception becomes a Sentry event with the original exception attached" do
      try do
        raise "scanner exploded"
      rescue
        exception -> Sentry.capture_exception(exception, stacktrace: __STACKTRACE__)
      end

      assert [%Sentry.Event{} = event] = Sentry.Test.pop_sentry_reports()
      assert event.original_exception == %RuntimeError{message: "scanner exploded"}
    end
  end

  describe "configuration" do
    test "is disabled without a DSN, so dev and test are silent by default" do
      # The whole design depends on this: no per-env opt-out exists, so if a
      # missing DSN did NOT disable the SDK, tests would post to Sentry.
      assert is_nil(Application.get_env(:sentry, :dsn))
    end

    test "tags events with the environment so prod issues are distinguishable" do
      assert Application.get_env(:sentry, :environment_name) == :test
    end
  end

  describe "request context" do
    test "every live_session carries the Sentry hook" do
      # Asserted against the compiled router rather than the source text, so
      # this cannot be fooled by the word appearing in a comment.
      by_session =
        TabletopWeb.Router.__routes__()
        |> Enum.flat_map(fn route ->
          case route.metadata do
            %{phoenix_live_view: {_mod, _action, _opts, %{name: name, extra: extra}}} ->
              hook_ids = extra |> Map.get(:on_mount, []) |> Enum.map(& &1.id)
              [{name, hook_ids}]

            _ ->
              []
          end
        end)
        |> Map.new()

      assert map_size(by_session) > 0, "no live_sessions found — has the router changed shape?"

      # `:live_dashboard` belongs to phoenix_live_dashboard, not to this app. A
      # crash inside it is still reported (the LoggerHandler captures crashes
      # regardless of the hook); the hook only adds request context, which is
      # not worth much on a single-operator diagnostic page.
      app_sessions = Map.drop(by_session, [:live_dashboard])

      missing =
        for {name, hook_ids} <- app_sessions,
            not Enum.any?(hook_ids, &match?({Sentry.LiveViewHook, _}, &1)),
            do: name

      assert missing == [],
             "live_session(s) #{inspect(missing)} have no Sentry.LiveViewHook — a LiveView " <>
               "error there would be reported with no request URL, user or breadcrumbs."
    end

    test "PlugContext is in the browser pipeline, PlugCapture is not used" do
      # PlugCapture is Cowboy-only; on Bandit it produces duplicate events.
      # Comments are stripped so the explanatory prose above the plug — which
      # necessarily names PlugCapture — cannot satisfy or break the assertion.
      source =
        ["lib/tabletop_web/router.ex", "lib/tabletop_web/endpoint.ex"]
        |> Enum.map_join("\n", &File.read!/1)
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
        |> Enum.join("\n")

      assert source =~ "Sentry.PlugContext"
      refute source =~ "Sentry.PlugCapture"
    end

    test "the live socket exposes the connect_info the hook reads" do
      config = TabletopWeb.Endpoint.config(:live_view) || []
      socket_info = connect_info_for_live_socket()

      for key <- [:peer_data, :uri, :user_agent] do
        assert key in socket_info,
               "#{inspect(key)} missing from live socket connect_info — " <>
                 "Sentry.LiveViewHook degrades silently without it. Got: #{inspect(socket_info)}"
      end

      # Session must survive alongside the added keys, or auth breaks entirely.
      assert Enum.any?(socket_info, &match?({:session, _}, &1))
      assert is_list(config)
    end
  end

  # `__sockets__/0` returns {path, module, opts}; the connect_info lives under
  # the websocket transport opts.
  defp connect_info_for_live_socket do
    {_path, _mod, opts} =
      Enum.find(TabletopWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/live" end)

    opts
    |> Keyword.fetch!(:websocket)
    |> Keyword.fetch!(:connect_info)
  end

  defp start_collecting_sentry_reports(_context) do
    Sentry.Test.start_collecting_sentry_reports()
  end
end
