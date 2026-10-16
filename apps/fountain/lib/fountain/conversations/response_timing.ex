defmodule Fountain.Conversations.ResponseTiming do
  @moduledoc """
  Matched request phases, measured on this node's monotonic clock.

  Scoped collection belongs to the process doing setup; only completed intervals
  travel with a prompt or the conversation state. Parallel bootstrap work is one
  wall-clock interval, not a sum of child spans. Nested intervals take precedence.
  Uncovered time before turn start is explicitly admission/queue/bookkeeping.
  """
  require OpenTelemetry.Tracer
  alias OpenTelemetry.{Span, Tracer}

  @key {__MODULE__, :intervals}
  @depth {__MODULE__, :depth}
  @phases ~w(admission_queue sandbox bootstrap runtime_session prompt_text)

  def now, do: System.monotonic_time(:millisecond)

  def collect(fun) do
    old = Process.put(@key, [])
    depth = Process.put(@depth, 0)

    try do
      result = fun.()
      {result, Process.get(@key)}
    after
      restore(@key, old)
      restore(@depth, depth)
    end
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)

  def measure(phase, fun) do
    if Process.get(@key) do
      started = now()
      depth = Process.get(@depth)
      Process.put(@depth, depth + 1)

      try do
        fun.()
      after
        Process.put(@depth, depth)
        interval = %{phase: phase, start: started, stop: now(), depth: depth}
        Process.put(@key, [interval | Process.get(@key)])
      end
    else
      fun.()
    end
  end

  def provision(fun) do
    {result, intervals} = collect(fn -> measure("bootstrap", fun) end)

    case result do
      {:noreply, state} -> {:noreply, Map.put(state, :response_setup, intervals)}
      other -> other
    end
  end

  def carry(meta) do
    case Keyword.get(meta, :response_timing) do
      nil ->
        meta

      timing ->
        Keyword.put(meta, :response_timing, Map.put(timing, :intervals, Process.get(@key, [])))
    end
  end

  def attach(metrics, meta, state) do
    case {metrics, Keyword.get(meta, :response_timing)} do
      {nil, _} ->
        nil

      {_, nil} ->
        metrics

      {_, timing} ->
        intervals = Map.get(timing, :intervals, []) ++ Map.get(state, :response_setup, [])
        Map.put(metrics, :response_timing, Map.put(timing, :intervals, intervals))
    end
  end

  def prompt_sent(nil, _time), do: nil
  def prompt_sent(metrics, time), do: Map.put_new(metrics, :prompt_sent_mono, time)

  @doc "Partition a request into exclusive intervals; warm/unused phases remain zero."
  def segments(timing, turn_start, prompt_sent, finished) do
    started = timing.started_mono
    turn_start = min(max(turn_start, started), finished)
    prompt_sent = min(max(prompt_sent, turn_start), finished)

    intervals =
      Map.get(timing, :intervals, [])
      |> Enum.map(&%{&1 | start: max(&1.start, started), stop: min(&1.stop, turn_start)})
      |> Enum.filter(&(&1.stop > &1.start))

    points = [started, turn_start] ++ Enum.flat_map(intervals, &[&1.start, &1.stop])

    before =
      points
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        active = Enum.filter(intervals, &(&1.start <= a and &1.stop >= b))

        phase =
          case Enum.max_by(active, & &1.depth, fn -> nil end) do
            nil -> "admission_queue"
            interval -> interval.phase
          end

        {phase, a, b}
      end)

    before ++
      [{"runtime_session", turn_start, prompt_sent}, {"prompt_text", prompt_sent, finished}]
  end

  def first_text(metrics, metadata, turn_span, finished) do
    with %{started_mono: started, path: path} = timing <- Map.get(metrics, :response_timing),
         sent when is_integer(sent) <- Map.get(metrics, :prompt_sent_mono) do
      segments = segments(timing, metrics.started_mono, sent, finished)

      totals =
        Enum.reduce(segments, Map.new(@phases, &{&1, 0}), fn {phase, a, b}, acc ->
          Map.update!(acc, phase, &(&1 + b - a))
        end)

      metadata = Map.put(metadata, :path, path)

      for {phase, elapsed} <- totals do
        Fountain.Telemetry.event([:response, :phase], Map.put(metadata, :phase, phase), %{
          elapsed_ms: elapsed
        })
      end

      attrs = Map.new(totals, fn {phase, ms} -> {"response_phase_" <> phase <> "_ms", ms} end)
      Fountain.Conversations.TurnMachine.stamp_span(turn_span, attrs)
      waterfall(started, finished, segments, Map.merge(metadata, attrs), turn_span)
    else
      _ -> :ok
    end
  end

  def completed(metrics, metadata, status) do
    case Map.get(metrics, :response_timing) do
      %{path: path} ->
        Fountain.Telemetry.event(
          [:response, :completed],
          Map.merge(metadata, %{path: path, status: status, text: to_string(metrics.first_text?)}),
          %{count: 1}
        )

      _ ->
        :ok
    end
  end

  # A dedicated request span contains the phases that predate the turn span.
  # Keep it in the turn's trace, with explicit original times, for a waterfall.
  defp waterfall(started, finished, segments, metadata, turn_span) do
    previous = Tracer.current_span_ctx()
    Tracer.set_current_span(turn_span)

    root =
      Tracer.start_span("fountain.response", %{start_time: native(started), attributes: metadata})

    Tracer.set_current_span(root)

    try do
      for {phase, a, b} <- segments, b > a do
        child =
          Tracer.start_span("fountain.response." <> phase, %{
            start_time: native(a),
            attributes: %{phase: phase}
          })

        Span.end_span(child, native(b))
      end
    after
      Span.end_span(root, native(finished))
      Tracer.set_current_span(previous)
    end
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
end
