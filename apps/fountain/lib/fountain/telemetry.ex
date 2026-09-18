defmodule Fountain.Telemetry do
  @moduledoc """
  Custom telemetry events emitted by AoD's hot path. Two flavours:

  * `[:fountain, :<thing>, :<verb>, :start | :stop | :exception]` —
    `:telemetry.span/3`-style events, suitable for `OpentelemetryTelemetry`
    auto-instrumentation. Wrap any work whose duration matters.
  * Plain `:telemetry.execute/3` events for one-shot signals (a sandbox
    transitioned to ready, a turn started running) where there is no
    natural duration.

  ## Why not OpenTelemetry directly?

  OTel's BEAM libs add real setup ceremony and are easy to misconfigure
  in dev. Emitting plain `:telemetry` events is portable: an operator can
  attach `OpentelemetryTelemetry.attach/3` to map them onto OTel spans
  whenever they're ready, without us locking the app to the OTel runtime.

  ## Helpers

      Fountain.Telemetry.span([:provision, :install_packages], %{conv_id: id}, fn ->
        ... do the work ...
        {result, %{packages: 5}}
      end)

  Returns whatever the closure returns. Records `:start` + `:stop` (or
  `:exception`) events tagged under `[:fountain | name]`.

      Fountain.Telemetry.event([:turn, :queued], %{conv_id: id, turn_number: 2}, %{count: 1})
  """

  @prefix [:fountain]

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Wrap work in *both* a `:telemetry.span/3` event pair and an OTel span.

  The closure must return `{result, extra_metadata}` (typical
  `:telemetry.span/3` signature). The OTel span gets the merged
  metadata as attributes; if `extra_metadata.outcome` is
  `:failed`/`:error` the span is marked as an error.

  Existing callers don't change. Adding new instrumentation is a
  single line: wrap the work, return `{result, %{}}`.
  """
  def span(name, metadata, fun) when is_list(name) and is_map(metadata) and is_function(fun, 0) do
    label = Enum.join(@prefix ++ name, ".")
    parent = Tracer.start_span(label, %{attributes: span_attributes(metadata)})
    previous = Tracer.set_current_span(parent)

    try do
      :telemetry.span(@prefix ++ name, metadata, fn ->
        {result, extra} = fun.()

        for {k, v} <- span_attributes(extra), do: Tracer.set_attribute(k, v)

        case Map.get(extra, :outcome) do
          o when o in [:failed, :error] ->
            Tracer.set_status(OpenTelemetry.status(:error, inspect(extra)))

          _ ->
            :ok
        end

        {result, extra}
      end)
    after
      # No-arg on purpose: end_span/1's argument is a *timestamp*, not a span
      # — passing `parent` here handed a span_ctx record to the timestamp
      # parameter. It never blew up because non-recording spans short-circuit
      # before touching it, but a recording span got a corrupt end time. The
      # current span *is* `parent` at this point, which is what no-arg ends.
      Tracer.end_span()
      Tracer.set_current_span(previous)
    end
  end

  # OTel span attribute values must be strings, numbers, booleans, or
  # arrays of those. PIDs / refs / functions / structs get inspected.
  defp span_attributes(metadata) when is_map(metadata) do
    metadata
    |> Enum.flat_map(fn
      {_, v} when is_pid(v) or is_reference(v) or is_function(v) -> []
      {k, v} when is_binary(v) or is_number(v) or is_boolean(v) -> [{to_string(k), v}]
      {k, v} when is_atom(v) -> [{to_string(k), Atom.to_string(v)}]
      {k, v} when is_list(v) -> [{to_string(k), inspect(v)}]
      {k, v} -> [{to_string(k), inspect(v)}]
    end)
    |> Map.new()
  end

  defp span_attributes(_), do: %{}

  @doc "Emit a one-shot event under the `:fountain` prefix."
  def event(name, metadata \\ %{}, measurements \\ %{}) when is_list(name) do
    :telemetry.execute(@prefix ++ name, measurements, metadata)
  end

  @doc """
  Default telemetry → log handler. Renders every emitted event as a
  single JSON line on stdout. Cheap structured logging for free; an
  operator who wants real OTel attaches their own handler instead and
  detaches this one.
  """
  def attach_default_logger do
    # These lists must name events something actually emits — a subscription
    # to a name that never fires logs nothing and looks identical to healthy
    # silence (#310). Span names: ConversationServer wraps fresh_provision,
    # reattach and setup_script; Provisioning wraps packages, network_policy,
    # clone_repositories and checkpoint create/restore; Rehydrator wraps its
    # post-boot sweep in rehydrate.
    #
    # Every provisioning span here also has a `distribution(...)` in
    # FountainWeb.Telemetry.prometheus_metrics/0 (#537). A new span wants both
    # — this list to make it visible in the logs, that one to make it
    # trendable — and metrics_test pins the pairing.
    spans =
      for stage <-
            ~w(fresh_provision reattach setup_script packages network_policy clone_repositories rehydrate)a,
          phase <- ~w(start stop exception)a,
          do: @prefix ++ [stage, phase]

    checkpoint_spans =
      for op <- ~w(create restore)a,
          phase <- ~w(start stop exception)a,
          do: @prefix ++ [:checkpoint, op, phase]

    one_shots = [
      @prefix ++ [:stage],
      @prefix ++ [:turn, :first_output],
      @prefix ++ [:turn, :completed],
      @prefix ++ [:sandbox, :reclaimed],
      @prefix ++ [:sandbox, :suspended],
      @prefix ++ [:reaper, :run],
      @prefix ++ [:reaper, :teardowns],
      @prefix ++ [:reaper, :untracked],
      @prefix ++ [:usage, :dropped]
    ]

    :telemetry.attach_many(
      "aod-default-logger",
      spans ++ checkpoint_spans ++ one_shots,
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(event_name, measurements, metadata, _config) do
    require Logger

    payload =
      %{
        event: Enum.join(event_name, "."),
        measurements: stringify(measurements),
        metadata: stringify(metadata)
      }
      |> Jason.encode!()

    Logger.info(payload)
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_pid(v), do: inspect(v)
  defp stringify_value(v) when is_reference(v), do: inspect(v)
  defp stringify_value(v) when is_tuple(v), do: inspect(v)
  defp stringify_value(v) when is_function(v), do: inspect(v)
  defp stringify_value(v), do: v

  @doc """
  No-op kept as an attach hook for future operator-provided handlers.

  Custom OTel spans are emitted directly inside `span/3` (it wraps the
  closure with `OpenTelemetry.Tracer.with_span/3`), so no bridge is
  needed. `opentelemetry_phoenix` + `opentelemetry_ecto` cover HTTP
  and DB.
  """
  def attach_otel_bridge, do: :ok

  @doc """
  Returns the current span context as a W3C Trace Context (`traceparent`)
  string, suitable for forwarding into a sprite as an env var so child
  processes (claude / codex / etc.) tag their API calls into our trace.
  Returns `nil` when there's no active span (or the OTel exporter is
  configured as `:none`).
  """
  def current_traceparent do
    headers = :otel_propagator_text_map.inject([])

    case List.keyfind(headers, "traceparent", 0) do
      {"traceparent", value} when is_binary(value) -> value
      {"traceparent", value} when is_list(value) -> List.to_string(value)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
