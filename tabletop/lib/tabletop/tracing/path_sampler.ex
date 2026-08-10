defmodule Tabletop.Tracing.PathSampler do
  @moduledoc """
  Root-span sampler that drops traces for uninteresting request paths.

  Exists to keep infrastructure polling out of Tempo. Fly hits `/health` on the
  configured `interval` and scrapes `/metrics` every 15s — together thousands of
  spans a day that carry no information and, on Grafana Cloud, are billed like
  any other span.

  ## Why a sampler rather than a filter

  `opentelemetry_bandit` has no ignore-path option, and the telemetry events it
  listens to are global, so both the main endpoint and
  `Tabletop.PromEx.MetricsServer` produce spans from the same handler. A sampler
  is the mechanism OpenTelemetry provides for this: the decision is made at span
  start, before attributes are enriched or child spans exist, so a dropped
  request costs almost nothing.

  Dropping is safe to do at the root because this sampler is installed as the
  `root` of a `parent_based` sampler (see `config/config.exs`). Child spans
  inherit the parent's decision, so the Ecto queries issued inside a health
  check disappear along with it — without a second rule.

  Spans with no `url.path` attribute are always sampled. That covers every
  non-HTTP root span, such as a query issued from a `Tabletop.Games.GameSession`
  with no request above it; those must not be silently dropped just because they
  lack a path.
  """

  @behaviour :otel_sampler

  # Set by opentelemetry_bandit at span start from `conn.request_path`, so it is
  # available to the sampler. Query strings live in `url.query`, so an exact
  # match on the path is enough.
  @url_path :"url.path"

  @impl true
  def setup(%{ignore_paths: paths}), do: %{ignore_paths: MapSet.new(paths)}
  def setup(_opts), do: %{ignore_paths: MapSet.new()}

  @impl true
  def description(_config), do: "TabletopPathSampler"

  @impl true
  def should_sample(ctx, _trace_id, _links, _span_name, _span_kind, attributes, config) do
    tracestate = ctx |> :otel_tracer.current_span_ctx() |> :otel_span.tracestate()

    {decision(attributes, config), [], tracestate}
  end

  defp decision(attributes, %{ignore_paths: ignore_paths}) do
    case fetch_path(attributes) do
      {:ok, path} ->
        if MapSet.member?(ignore_paths, path), do: :drop, else: :record_and_sample

      :error ->
        # Not an HTTP root span — nothing to match on, so keep it.
        :record_and_sample
    end
  end

  # Attributes arrive as a map at span start. The value is a binary; normalise
  # charlists defensively since the attribute is set by a third-party library.
  defp fetch_path(attributes) when is_map(attributes) do
    case Map.fetch(attributes, @url_path) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      {:ok, path} when is_list(path) -> {:ok, to_string(path)}
      _ -> :error
    end
  end

  defp fetch_path(_attributes), do: :error
end
