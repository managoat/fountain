defmodule Fountain.Conversations.ConversationServerTurnMetricsTest do
  @moduledoc """
  Producer side of the turn metrics — duration (#536) and time to first
  token (#535).

  `FountainWeb.Telemetry` declares histograms over
  `[:fountain, :turn, :completed]` and `[:fountain, :turn, :first_output]`;
  a metric subscribed to an event nobody emits scrapes empty forever and
  looks exactly like a healthy quiet system (#310). These pin that
  ConversationServer actually fires them, on every path that ends a turn and
  on the first byte out of the sandbox, with the tags the histograms read.
  """

  use Fountain.ConversationServerCase

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "gemini")
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, conv: conv}
  end

  # Forward turn metric events to the test process for the duration of one
  # test. Handler ids are per-test so parallel modules can't collide — these
  # are async: false, but the handler table is global either way.
  defp capture_turn_completed, do: capture([:fountain, :turn, :completed], :turn_completed)

  defp capture_first_output, do: capture([:fountain, :turn, :first_output], :first_output)

  defp capture(event, tag) do
    test_pid = self()
    handler_id = "turn-metrics-#{tag}-#{inspect(test_pid)}"

    :telemetry.attach(
      handler_id,
      event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {tag, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp start_with_turn(conv, prompt_opts \\ []) do
    stub_happy_sprite()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

    {pid, _mon, :alive} = start_server(conv, initial_prompt: "first", prompt_opts: prompt_opts)
    {pid, ref}
  end

  test "request clock reaches the first text event through prompt admission", %{conv: conv} do
    capture([:fountain, :response, :first_text], :response_text)
    capture([:fountain, :response, :phase], :response_phase)
    capture([:fountain, :response, :completed], :response_completed)
    started = System.monotonic_time(:millisecond) - 1000
    {pid, ref} = start_with_turn(conv, response_timing: %{started_mono: started, path: "cold"})

    line =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{
          update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "echo"}}
        }
      })

    send(pid, {:acp, ref, {:prompt_timing, System.monotonic_time(:millisecond)}})
    send(pid, {:acp, ref, {:lines, "acp", line}})
    _ = :sys.get_state(pid)

    assert_received {:response_text, %{elapsed_ms: elapsed},
                     %{path: "cold", provider: "sprites", turn_class: "first"}}

    assert elapsed >= 1000

    phases =
      for _ <- 1..5 do
        assert_receive {:response_phase, %{elapsed_ms: duration}, %{path: "cold", phase: phase}}
        {phase, duration}
      end

    assert Enum.sum(Enum.map(phases, &elem(&1, 1))) == elapsed
    send(pid, {:acp, ref, {:lines, "acp", line}})
    _ = :sys.get_state(pid)
    refute_received {:response_phase, _, _}
    send(pid, {:exit, %{ref: ref}, 0})
    _ = :sys.get_state(pid)
    assert_received {:response_completed, _, %{path: "cold", status: "completed", text: "true"}}
    GenServer.stop(pid)
  end

  test "failure before text emits an outcome without a successful phase sample", %{conv: conv} do
    capture([:fountain, :response, :completed], :response_completed)
    capture([:fountain, :response, :phase], :response_phase)

    {pid, ref} =
      start_with_turn(conv,
        response_timing: %{started_mono: System.monotonic_time(:millisecond), path: "wake"}
      )

    send(pid, {:exit, %{ref: ref}, 1})
    _ = :sys.get_state(pid)
    assert_received {:response_completed, _, %{path: "wake", status: "failed", text: "false"}}
    refute_received {:response_phase, _, _}
    GenServer.stop(pid)
  end

  describe "[:fountain, :turn, :completed]" do
    test "a clean exit emits a duration tagged runtime + completed", %{conv: conv} do
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, measurements, metadata}
      assert metadata.runtime == "gemini"
      assert metadata.provider == "sprites"
      assert metadata.status == "completed"

      # Metadata, never a tag: it's what makes the JSON log line point at a
      # conversation, and as a label it would mint a series per conversation.
      assert metadata.conv_id == conv.id

      # Milliseconds, not native units or seconds: the histogram's buckets
      # are in ms and a unit mix-up puts every turn in the first or last one.
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert measurements.duration_ms < 60_000

      GenServer.stop(pid)
    end

    test "a non-zero exit emits with status failed", %{conv: conv} do
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, _measurements, %{status: "failed"}}

      GenServer.stop(pid)
    end

    test "a dropped sprite socket mid-turn still emits (#413)", %{conv: conv} do
      # This path fails the turn without an :exit ever arriving. Left out, a
      # runtime whose sockets drop would look like it had no slow turns at
      # all — the histogram would simply lose those samples.
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, _measurements, %{status: "failed"}}

      GenServer.stop(pid)
    end

    test "an interrupt emits with status interrupted", %{conv: conv} do
      capture_turn_completed()
      {pid, _ref} = start_with_turn(conv)

      assert :ok = GenServer.call(pid, :interrupt)

      assert_received {:turn_completed, _measurements, %{status: "interrupted"}}

      GenServer.stop(pid)
    end

    test "a spawn that never starts emits nothing", %{conv: conv} do
      # There is no run to time — the turn is marked failed before any
      # command exists. A sample here would be a few milliseconds of "turn
      # duration" dragging the histogram's low end down.
      capture_turn_completed()
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:error, :econnrefused}
      end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      refute_received {:turn_completed, _, _}

      GenServer.stop(pid)
    end

    test "one turn emits exactly one sample", %{conv: conv} do
      # The stamp is cleared on the terminal path. If it were not, a stale
      # one would attach to the next turn and report a duration spanning
      # both.
      capture_turn_completed()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)

      assert_received {:turn_completed, _, _}
      refute_received {:turn_completed, _, _}

      GenServer.stop(pid)
    end
  end

  describe "[:fountain, :turn, :first_output]" do
    test "the first stdout chunk reports elapsed time tagged by runtime", %{conv: conv} do
      capture_first_output()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:stdout, %{ref: ref}, "thinking..."})
      _ = :sys.get_state(pid)

      assert_received {:first_output, measurements, metadata}
      assert metadata.runtime == "gemini"
      assert metadata.provider == "sprites"
      assert metadata.conv_id == conv.id
      assert is_integer(measurements.elapsed_ms)
      assert measurements.elapsed_ms >= 0
      assert measurements.elapsed_ms < 60_000

      GenServer.stop(pid)
    end

    test "only the first chunk reports — the rest of the stream is free", %{conv: conv} do
      # A streaming turn produces thousands of chunks. Emitting on each
      # would make TTFT indistinguishable from "time to last token" and put
      # a telemetry dispatch on every byte of the hot path.
      capture_first_output()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:stdout, %{ref: ref}, "first"})
      send(pid, {:stdout, %{ref: ref}, "second"})
      send(pid, {:stdout, %{ref: ref}, "third"})
      _ = :sys.get_state(pid)

      assert_received {:first_output, _, _}
      refute_received {:first_output, _, _}

      GenServer.stop(pid)
    end

    test "each turn reports its own first output", %{conv: conv} do
      # The flag lives with the turn's stamp and is dropped with it, so turn
      # 2 measures turn 2. A flag that survived the turn would leave every
      # conversation contributing exactly one sample, forever.
      capture_first_output()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:stdout, %{ref: ref}, "turn one output"})
      send(pid, {:exit, %{ref: ref}, 0})
      _ = :sys.get_state(pid)
      assert_received {:first_output, _, _}

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      send(pid, {:stdout, %{ref: ref}, "turn two output"})
      _ = :sys.get_state(pid)
      assert_received {:first_output, _, _}

      GenServer.stop(pid)
    end

    test "a turn with no output before it exits reports nothing", %{conv: conv} do
      # Nothing to measure — the sandbox never spoke. A zero here would read
      # as an instant first token, which is the opposite of what happened.
      capture_first_output()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      refute_received {:first_output, _, _}

      GenServer.stop(pid)
    end

    test "stderr alone does not count as first output", %{conv: conv} do
      # The metric is first *output*, and every runtime's actual answer comes
      # down stdout; a warning on stderr at startup would otherwise report a
      # TTFT of a few milliseconds for a turn that hadn't started yet.
      capture_first_output()
      {pid, ref} = start_with_turn(conv)

      send(pid, {:stderr, %{ref: ref}, "npm notice: new version available"})
      _ = :sys.get_state(pid)

      refute_received {:first_output, _, _}

      send(pid, {:stdout, %{ref: ref}, "hello"})
      _ = :sys.get_state(pid)
      assert_received {:first_output, _, _}

      GenServer.stop(pid)
    end
  end
end
