defmodule Fountain.Conversations.ResponseTimingTest do
  use ExUnit.Case, async: true
  alias Fountain.Conversations.ResponseTiming

  setup do
    test = self()
    id = {__MODULE__, make_ref()}
    conv_id = "response-timing-" <> Integer.to_string(System.unique_integer([:positive]))

    :telemetry.attach_many(
      id,
      [
        [:fountain, :response, :first_text],
        [:fountain, :response, :phase],
        [:fountain, :response, :completed]
      ],
      # Only this test's events: other tests' turns emit the same names.
      fn event, measurements, meta, _ ->
        if meta[:conv_id] == conv_id, do: send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    labels = %{
      runtime: "codex",
      provider: "sprites",
      turn_class: "first",
      conv_id: conv_id,
      turn_id: "t"
    }

    %{labels: labels}
  end

  defp first_text(meta, elapsed_ms) do
    ResponseTiming.handle([:fountain, :turn, :first_text], %{elapsed_ms: elapsed_ms}, meta, nil)
  end

  test "the three phases are exclusive and add up to request → first text" do
    assert ResponseTiming.phases(0, 900, 1_000, 1_100) == [
             {"setup", 900},
             {"runtime_session", 100},
             {"prompt_text", 100}
           ]
  end

  test "a boundary out of order shrinks a phase to zero rather than below it" do
    # A turn that started before the request clock (a warm prompt queued behind
    # a running turn) has no setup; a prompt write stamped before turn start
    # has no session phase.
    assert ResponseTiming.phases(100, 50, 40, 300) == [
             {"setup", 0},
             {"runtime_session", 0},
             {"prompt_text", 200}
           ]
  end

  test "first text emits the headline and one sample per phase, labelled by path", %{
    labels: labels
  } do
    meta =
      Map.merge(labels, %{
        span: nil,
        turn_started_mono: 1_000,
        prompt_sent_mono: 1_300,
        response_timing: %{started_mono: 0, path: "wake"}
      })

    first_text(meta, 500)

    assert_receive {:telemetry, [:fountain, :response, :first_text], %{elapsed_ms: 1_500},
                    %{path: "wake", runtime: "codex", provider: "sprites"} = emitted}

    refute Map.has_key?(emitted, :span)

    for {phase, ms} <- [{"setup", 1_000}, {"runtime_session", 300}, {"prompt_text", 200}] do
      assert_receive {:telemetry, [:fountain, :response, :phase], %{elapsed_ms: ^ms},
                      %{phase: ^phase, path: "wake"}}
    end
  end

  test "a turn without a prompt-write timestamp gets the headline but no phases", %{
    labels: labels
  } do
    meta =
      Map.merge(labels, %{
        turn_started_mono: 1_000,
        prompt_sent_mono: nil,
        response_timing: %{started_mono: 0, path: "cold"}
      })

    first_text(meta, 500)

    assert_receive {:telemetry, [:fountain, :response, :first_text], %{elapsed_ms: 1_500}, _}
    refute_received {:telemetry, [:fountain, :response, :phase], _, _}
  end

  test "a turn without a request clock emits no response samples", %{labels: labels} do
    first_text(Map.merge(labels, %{turn_started_mono: 1_000, prompt_sent_mono: 1_100}), 500)

    refute_received {:telemetry, [:fountain, :response, _], _, _}
  end

  test "a timed turn's end is counted by path, status and whether text arrived", %{
    labels: labels
  } do
    meta = Map.merge(labels, %{status: "failed", response_path: "cold", text: false})
    ResponseTiming.handle([:fountain, :turn, :completed], %{duration_ms: 10}, meta, nil)

    assert_receive {:telemetry, [:fountain, :response, :completed], %{count: 1},
                    %{path: "cold", status: "failed", text: "false"}}

    untimed = %{meta | response_path: nil}
    ResponseTiming.handle([:fountain, :turn, :completed], %{duration_ms: 10}, untimed, nil)
    refute_received {:telemetry, [:fountain, :response, :completed], _, _}
  end
end
