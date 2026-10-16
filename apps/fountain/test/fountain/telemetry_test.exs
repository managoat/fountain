defmodule Fountain.TelemetryTest do
  use ExUnit.Case, async: false
  require OpenTelemetry.Tracer
  require Record
  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :gen_statem.call(:otel_simple_processor_global, {:set_exporter, :none}) end)
    :ok
  end

  # The one exported span with this name. Drains rather than counting: how many
  # spans a response waterfall emits depends on how many phases the request
  # actually used.
  defp exported_span(name) do
    assert_receive {:span, item}, 1_000

    if span(item, :name) == name, do: item, else: exported_span(name)
  end

  test "response waterfall shares the turn trace and keeps exclusive original timestamps" do
    alias Fountain.Conversations.ResponseTiming
    alias OpenTelemetry.{Tracer, Span}
    original = Tracer.current_span_ctx()
    parent = Tracer.start_span("test.turn")
    now = System.monotonic_time(:millisecond)

    metrics = %{
      started_mono: now - 100,
      prompt_sent_mono: now - 40,
      response_timing: %{started_mono: now - 200, path: "cold", intervals: []}
    }

    ResponseTiming.first_text(
      metrics,
      %{provider: "e2b", runtime: "codex", turn_id: "test"},
      parent,
      now
    )

    assert Tracer.current_span_ctx() == original

    recorded =
      for _ <- 1..4 do
        assert_receive {:span, item}
        item
      end

    root = Enum.find(recorded, &(span(&1, :name) == "fountain.response"))
    children = Enum.reject(recorded, &(&1 == root))
    assert length(children) == 3
    assert Enum.all?(children, &(span(&1, :parent_span_id) == span(root, :span_id)))
    assert Enum.all?(recorded, &(span(&1, :trace_id) == Span.trace_id(parent)))

    assert Enum.sum(Enum.map(children, &(span(&1, :end_time) - span(&1, :start_time)))) ==
             span(root, :end_time) - span(root, :start_time)

    Span.end_span(parent)
  end

  test "the runtime-session breakdown closes against its phase on the turn span" do
    # #2907: the per-step attributes are stamped as each step lands, but the
    # residual needs the phase total, which does not exist until the prompt
    # write is timestamped. So it is stamped here, on the same span, and a
    # reader can check the steps against the phase without a join.
    alias Fountain.Conversations.{ResponseTiming, StartupAttribution, TurnMachine}
    alias OpenTelemetry.{Span, Tracer}

    parent = Tracer.start_span("test.turn")
    now = System.monotonic_time(:millisecond)

    metrics =
      %{
        started_mono: now - 300,
        prompt_sent_mono: now - 100,
        response_timing: %{started_mono: now - 300, path: "cold", intervals: []}
      }
      |> TurnMachine.attribute_startup(%{"adapter_check" => 20, "sandbox_spawn" => 30})
      |> TurnMachine.attribute_startup(%{"initialize" => 40, "session/new" => 50})

    ResponseTiming.first_text(metrics, %{provider: "sprites", runtime: "claude"}, parent, now)

    Span.end_span(parent)

    turn = exported_span("test.turn")
    attrs = elem(span(turn, :attributes), 4)

    # The phase is turn_start → prompt_sent: 200 ms here, 140 of it attributed.
    assert attrs["response_phase_runtime_session_ms"] == 200
    assert attrs["acp.startup.attributed_ms"] == 140
    assert attrs["acp.startup.residual_ms"] == 60
    assert attrs["acp.startup.adapter_check_ms"] == 20
    assert attrs["acp.startup.session_new_ms"] == 50

    # A step that did not happen is absent, not zero.
    refute Map.has_key?(attrs, "acp.startup.authenticate_ms")

    assert StartupAttribution.attributed_ms(TurnMachine.startup_attribution(metrics)) == 140
  end

  test "recording parent and child spans both export with valid end times" do
    Fountain.Telemetry.span([:fresh_provision], %{provider: :e2b, runtime: "codex"}, fn ->
      Fountain.Telemetry.span([:provision_step], %{step: "adapter"}, fn -> {:ok, %{}} end)
      {:ok, %{}}
    end)

    assert_receive {:span, child}
    assert_receive {:span, parent}
    assert span(child, :name) == "fountain.provision_step"
    assert span(parent, :name) == "fountain.fresh_provision"
    assert span(child, :parent_span_id) == span(parent, :span_id)

    for recorded <- [parent, child] do
      assert is_integer(span(recorded, :end_time))
      assert span(recorded, :end_time) >= span(recorded, :start_time)
    end
  end

  test "tool spans export once and preserve the active context" do
    require OpenTelemetry.Tracer, as: Tracer
    parent = Tracer.start_span("test.turn")
    original = Tracer.current_span_ctx()
    tracer = Managoat.ACP.Tracer.new(parent)

    line = fn update ->
      Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: update}})
    end

    tracer =
      Managoat.ACP.Tracer.handle_line(
        tracer,
        line.(%{sessionUpdate: "tool_call", toolCallId: "a"})
      )

    assert Tracer.current_span_ctx() == original

    tracer =
      Managoat.ACP.Tracer.handle_line(
        tracer,
        line.(%{sessionUpdate: "tool_call_update", toolCallId: "a", status: "completed"})
      )

    assert_receive {:span, tool}
    assert is_integer(span(tool, :end_time))
    assert span(tool, :parent_span_id) == :otel_span.span_id(parent)
    Managoat.ACP.Tracer.finalize(tracer)
    assert Tracer.current_span_ctx() == original
    Fountain.Conversations.TurnMachine.end_span(parent, :ok, %{})
    assert_receive {:span, _}
    refute_receive {:span, _}
  end

  test "nested spans restore context and inherit only bounded latency labels" do
    prior = :otel_ctx.get_current()
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:fountain, :provision_step, :stop],
      fn _, _, meta, _ ->
        send(test, {:step, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    assert :done =
             Fountain.Telemetry.span(
               [:fresh_provision],
               %{provider: :sprites, runtime: "codex", conv_id: "private-id"},
               fn ->
                 parent = OpenTelemetry.Tracer.current_span_ctx()

                 Fountain.Telemetry.span([:provision_step], %{step: "adapter"}, fn ->
                   {:done, %{}}
                 end)

                 assert OpenTelemetry.Tracer.current_span_ctx() == parent
                 {:done, %{}}
               end
             )

    assert :otel_ctx.get_current() == prior
    assert_received {:step, %{provider: :sprites, runtime: "codex", step: "adapter"} = metadata}
    refute Map.has_key?(metadata, :conv_id)
  end

  test "exception metadata does not detach the JSON logger" do
    assert :ok =
             Fountain.Telemetry.handle(
               [:fountain, :fresh_provision, :exception],
               %{},
               %{
                 reason: %RuntimeError{message: "boom"},
                 stacktrace: [{__MODULE__, :test, 0, []}]
               },
               nil
             )
  end

  test "exceptions restore the caller context" do
    prior = :otel_ctx.get_current()

    assert_raise RuntimeError, "boom", fn ->
      Fountain.Telemetry.span([:fresh_provision], %{provider: :e2b}, fn -> raise "boom" end)
    end

    assert :otel_ctx.get_current() == prior
  end
end
