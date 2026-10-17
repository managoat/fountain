defmodule Fountain.TelemetrySampler do
  @moduledoc """
  The root sampler prod's tracer runs under `parent_based`: it drops a
  database query span that has no parent, and samples every other root.

  `opentelemetry_ecto` opens a span for every query. One inside a request,
  a turn or a provision step joins that trace; one outside them (Oban's
  polling, a stream's log reads, an API key lookup) becomes a trace of its
  own, a single span with nothing to say what it was for. Those were nine
  in ten of the spans prod exported, and they share the batch processor's
  queue (2048 by default) with the spans that matter: ten concurrent
  conversation starts filled it within a 5 s export window, and the
  processor dropped every span ending while it stayed full, about 30% of
  that wave's turn and response spans (measured 2026-10-17).

  Children follow their parent's decision, so a query inside a sampled
  trace is still recorded.
  """

  @query_span "fountain.repo.query"

  def setup(_opts), do: []

  def description(_config), do: "FountainRootSampler{drop parentless repo queries}"

  def should_sample(ctx, _trace_id, _links, name, _kind, _attributes, _config) do
    tracestate = ctx |> :otel_tracer.current_span_ctx() |> :otel_span.tracestate()
    {decision(name), [], tracestate}
  end

  defp decision(name) when is_binary(name) do
    if String.starts_with?(name, @query_span), do: :drop, else: :record_and_sample
  end

  defp decision(_name), do: :record_and_sample
end
