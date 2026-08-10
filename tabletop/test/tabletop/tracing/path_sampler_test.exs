defmodule Tabletop.Tracing.PathSamplerTest do
  @moduledoc """
  The sampler decides whether a trace exists at all, so a mistake here is
  invisible in Grafana — either infrastructure noise reappears, or real traffic
  silently stops being recorded. These tests pin both directions.
  """
  use ExUnit.Case, async: true

  alias Tabletop.Tracing.PathSampler

  @url_path :"url.path"

  defp config(paths \\ ["/health", "/metrics"]) do
    PathSampler.setup(%{ignore_paths: paths})
  end

  # should_sample/7 needs a context to read the parent tracestate from; an empty
  # context is what a root span actually gets.
  defp sample(attributes, config) do
    {decision, _attrs, _tracestate} =
      PathSampler.should_sample(:otel_ctx.new(), 123, [], :HTTP, :server, attributes, config)

    decision
  end

  describe "ignored paths" do
    test "drops the health check" do
      assert sample(%{@url_path => "/health"}, config()) == :drop
    end

    test "drops the metrics scrape" do
      assert sample(%{@url_path => "/metrics"}, config()) == :drop
    end
  end

  describe "sampled paths" do
    test "keeps ordinary application requests" do
      for path <- ["/", "/games/abc-123", "/tournaments", "/users/settings"] do
        assert sample(%{@url_path => path}, config()) == :record_and_sample,
               "#{path} should be traced"
      end
    end

    test "matches the path exactly rather than by prefix" do
      # A real route must not be dropped just because it starts with an ignored
      # path — /health-history is application traffic.
      for path <- ["/health-history", "/healthz", "/metrics-admin", "/health/detail"] do
        assert sample(%{@url_path => path}, config()) == :record_and_sample,
               "#{path} should not be swept up by the /health or /metrics rule"
      end
    end

    test "keeps non-HTTP root spans, which carry no url.path" do
      # e.g. an Ecto query from a GameSession with no request above it.
      assert sample(%{}, config()) == :record_and_sample
      assert sample(%{"db.system": :postgresql}, config()) == :record_and_sample
    end

    test "keeps everything when no paths are configured" do
      assert sample(%{@url_path => "/health"}, PathSampler.setup(%{})) == :record_and_sample
    end
  end

  describe "setup/1" do
    test "accepts a list and matches on membership" do
      config = PathSampler.setup(%{ignore_paths: ["/only-this"]})

      assert sample(%{@url_path => "/only-this"}, config) == :drop
      assert sample(%{@url_path => "/health"}, config) == :record_and_sample
    end

    test "tolerates missing options rather than raising at boot" do
      assert %{ignore_paths: empty} = PathSampler.setup(:no_opts)
      assert Enum.empty?(empty)
    end
  end

  describe "wiring" do
    test "is installed as the root of the configured parent_based sampler" do
      # Guards against the sampler existing but never being reached, and against
      # it being installed somewhere that would also judge child spans.
      assert {:parent_based, %{root: {PathSampler, %{ignore_paths: paths}}}} =
               Application.get_env(:opentelemetry, :sampler)

      assert "/health" in paths
      assert "/metrics" in paths
    end

    test "the configured paths are the ones the app actually serves" do
      # /health is a real route; /metrics is served by the PromEx listener on its
      # own port. If /health were ever renamed, this fails rather than leaving a
      # sampler rule quietly matching nothing.
      assert %{route: "/health"} =
               Phoenix.Router.route_info(TabletopWeb.Router, "GET", "/health", "host")

      assert Tabletop.PromEx.MetricsServer.__info__(:module)
    end
  end
end
