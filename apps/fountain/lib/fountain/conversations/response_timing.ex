defmodule Fountain.Conversations.ResponseTiming do
  @moduledoc """
  The `:telemetry` handler that turns a turn's timing events into span
  attributes and the request metrics.

  `TurnMachine` only emits `[:fountain, :turn, :first_output | :first_update |
  :first_text | :completed]`, with the turn's OTel span in the metadata. This
  handler, attached once at boot, stamps `<event>_ms` on that span. For a turn
  that carries a request clock (`response_timing`: when the request entered the
  application, and by which `path`), it also emits the headline,
  `[:fountain, :response, :first_text]`, one `[:fountain, :response, :phase]`
  sample per phase, and `[:fountain, :response, :completed]`.

  The phases are exclusive and add up to request → first text:

    * `setup` — request entry to turn start: admission and queueing, and on a
      cold or wake path the sandbox and its bootstrap. The
      `fountain.fresh_provision`, `fountain.reattach` and
      `fountain.provision_step` spans break it down;
    * `runtime_session` — turn start to the prompt write;
    * `prompt_text` — the prompt write to the first assistant text.

  A turn with no prompt-write timestamp (a turn restored after a restart)
  emits no phase samples rather than inventing them.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @handler "fountain-response-timing"
  @events [
    [:fountain, :turn, :first_output],
    [:fountain, :turn, :first_update],
    [:fountain, :turn, :first_text],
    [:fountain, :turn, :completed]
  ]

  @doc "Attach the handler. Idempotent."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle([:fountain, :turn, :first_output], %{elapsed_ms: ms}, meta, _config),
    do: stamp(meta, %{first_output_ms: ms})

  def handle([:fountain, :turn, :first_update], %{elapsed_ms: ms}, meta, _config),
    do: stamp(meta, %{first_update_ms: ms})

  def handle([:fountain, :turn, :first_text], %{elapsed_ms: ms}, meta, _config) do
    stamp(meta, %{
      first_text_ms: ms,
      provider: Map.get(meta, :provider),
      turn_class: Map.get(meta, :turn_class)
    })

    case meta do
      %{response_timing: %{started_mono: started, path: path}, turn_started_mono: turn_started}
      when is_integer(started) and is_integer(turn_started) ->
        first_text(meta, started, path, turn_started, turn_started + ms)

      _ ->
        :ok
    end
  end

  def handle([:fountain, :turn, :completed], _measurements, meta, _config) do
    case meta do
      %{response_path: path} when is_binary(path) ->
        Fountain.Telemetry.event(
          [:response, :completed],
          meta
          |> Map.take([:runtime, :provider, :turn_class, :status, :conv_id])
          |> Map.merge(%{path: path, text: to_string(Map.get(meta, :text, false))}),
          %{count: 1}
        )

      _ ->
        :ok
    end
  end

  def handle(_event, _measurements, _meta, _config), do: :ok

  @doc """
  Split request → first text into the three exclusive phases, in order.
  Each boundary is clamped into the request's lifetime, so a clock taken out
  of order shrinks a phase to zero rather than making one negative.
  """
  @spec phases(integer(), integer(), integer() | nil, integer()) :: [{String.t(), integer()}]
  def phases(started, turn_started, prompt_sent, now) do
    turn_started = turn_started |> max(started) |> min(now)
    prompt_sent = prompt_sent |> max(turn_started) |> min(now)

    [
      {"setup", turn_started - started},
      {"runtime_session", prompt_sent - turn_started},
      {"prompt_text", now - prompt_sent}
    ]
  end

  defp first_text(meta, started, path, turn_started, now) do
    labels =
      meta
      |> Map.take([:runtime, :provider, :turn_class, :conv_id, :turn_id])
      |> Map.put(:path, path)

    Fountain.Telemetry.event([:response, :first_text], labels, %{elapsed_ms: now - started})
    stamp(meta, %{response_first_text_ms: now - started, response_path: path})

    case Map.get(meta, :prompt_sent_mono) do
      sent when is_integer(sent) ->
        phases = phases(started, turn_started, sent, now)

        for {phase, elapsed} <- phases do
          Fountain.Telemetry.event([:response, :phase], Map.put(labels, :phase, phase), %{
            elapsed_ms: elapsed
          })
        end

        stamp(meta, Map.new(phases, fn {phase, ms} -> {"response_phase_#{phase}_ms", ms} end))

      _ ->
        :ok
    end
  end

  defp stamp(%{span: span}, attrs) when not is_nil(span) do
    previous = Tracer.current_span_ctx()
    Tracer.set_current_span(span)

    for {key, value} <- attrs, not is_nil(value), do: Tracer.set_attribute(to_string(key), value)

    Tracer.set_current_span(previous)
    :ok
  end

  defp stamp(_meta, _attrs), do: :ok
end
