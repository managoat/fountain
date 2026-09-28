defmodule Fountain.Conversations.ReadOnlyTest do
  @moduledoc """
  The parts of a read-only turn (#2533) that are rules rather than a run: what
  the managed policy says, what the wrapper does in a real shell, which idle
  peer a turn may ride, how the flag travels, and what happens when a server or
  an owner cannot enforce it. `ReadOnlyTurnTest` runs the whole turn.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Connection, PromptDelivery, ReadOnly, Turn}

  @moduletag :tmp_dir

  describe "the managed policy" do
    test "denies every built-in tool that writes, and ignores stored allow rules" do
      policy = Jason.decode!(ReadOnly.managed_settings())

      assert policy["allowManagedPermissionRulesOnly"] == true
      assert policy["disableAutoMode"] == "disable"
      assert policy["permissions"]["disableBypassPermissionsMode"] == "disable"
      assert policy["permissions"]["defaultMode"] == "default"

      for tool <- ~w(Bash Edit MultiEdit NotebookEdit Write),
          do: assert(tool in policy["permissions"]["deny"])

      refute Map.has_key?(policy["permissions"], "allow")
    end

    test "only claude enforces it" do
      assert ReadOnly.supported?("claude")

      for runtime <- ["codex", "gemini", "opencode", "acp", nil],
          do: refute(ReadOnly.supported?(runtime))

      assert ReadOnly.check(true, "claude") == :ok
      assert ReadOnly.check(true, "codex") == {:error, {:read_only_unsupported, "codex"}}
      # A normal prompt runs anywhere.
      assert ReadOnly.check(false, "codex") == :ok
      assert ReadOnly.check(nil, "codex") == :ok
    end
  end

  describe "the wrapper, in a real shell" do
    test "installs the policy and exports its directory to the adapter", %{tmp_dir: tmp_dir} do
      turn = %Turn{read_only: true}

      {cmd, args} =
        ReadOnly.command(turn, "sh", [
          "-c",
          ~S(printf '%s\n' "$CLAUDE_CODE_MANAGED_SETTINGS_PATH"; cat "$CLAUDE_CODE_MANAGED_SETTINGS_PATH/managed-settings.json"),
          "adapter"
        ])

      assert {out, 0} = System.cmd(cmd, args, env: [{"HOME", tmp_dir}])
      [dir, json] = String.split(out, "\n", parts: 2)

      assert dir == Path.join([tmp_dir, ".fountain", "read-only", "claude"])
      assert json == ReadOnly.managed_settings()
      # Written to a temporary name and moved into place: nothing left behind.
      assert File.ls!(dir) == ["managed-settings.json"]
    end

    test "a normal turn's argv is untouched" do
      assert ReadOnly.command(%Turn{read_only: false}, "claude-agent-acp", ["--x"]) ==
               {"claude-agent-acp", ["--x"]}
    end

    test "an adapter never starts when the policy cannot be written", %{tmp_dir: tmp_dir} do
      # `$HOME/.fountain` is a file, so the directory cannot be made.
      File.write!(Path.join(tmp_dir, ".fountain"), "")
      {cmd, args} = ReadOnly.command(%Turn{read_only: true}, "sh", ["-c", "echo started"])

      assert {out, 70} = System.cmd(cmd, args, env: [{"HOME", tmp_dir}], stderr_to_stdout: true)
      refute out =~ "started"
    end
  end

  describe "which idle peer a turn may ride" do
    defp state(env),
      do: %{turn_execution: nil, acp_model_env: env, runtime_module: Managoat.Runtimes.Claude}

    defp conv, do: %Conversations.Conversation{runtime: "claude", model: nil}

    test "a read-only turn never rides a writable adapter, nor the other way round" do
      writable = state([])
      read_only = state([{"FOUNTAIN_READ_ONLY", "1"}])
      ro_turn = %Turn{read_only: true}
      turn = %Turn{read_only: false}

      assert Connection.stale_reason(writable, false, conv(), nil, ro_turn) ==
               "read_only_changed"

      assert Connection.stale_reason(read_only, false, conv(), nil, turn) == "read_only_changed"
      assert Connection.stale_reason(read_only, false, conv(), nil, ro_turn) == nil
      assert Connection.stale_reason(writable, false, conv(), nil, turn) == nil
    end

    test "a reattached peer's spawn is unknown, so a read-only turn never takes it" do
      reattached = %{state(nil) | runtime_module: Managoat.Runtimes.Testing.FakeRuntime}

      assert Connection.stale_reason(reattached, false, conv(), nil, %Turn{read_only: true}) ==
               "read_only_changed"

      # A runtime that never varies its spawn env keeps it for a normal turn.
      assert Connection.stale_reason(reattached, false, conv(), nil, %Turn{read_only: false}) ==
               nil
    end

    test "a bounded turn has already left the idle peer" do
      bounded = %{state([]) | turn_execution: %{}}
      assert Connection.stale_reason(bounded, false, conv(), nil, %Turn{read_only: true}) == nil
    end
  end

  describe "how the flag travels" do
    test "only true travels, in the same message a client_request_id does" do
      me = self()

      assert PromptDelivery.travelling(read_only: true) == [read_only: true]

      for value <- [false, nil, "true", 1],
          do: assert(PromptDelivery.travelling(read_only: value) == [])

      assert {:send_prompt, "hi", [], [read_only: true]} =
               PromptDelivery.call(me, "hi", [], actor: "api", read_only: true)

      assert {"hi", [read_only: true]} = PromptDelivery.for_wake("hi", read_only: true)
      assert PromptDelivery.from_request(%{"read_only" => true}) == [read_only: true]
      assert PromptDelivery.from_request(%{"read_only" => false}) == []
    end

    test "the wake hands a read-only prompt over with its flag" do
      assert :ok = PromptDelivery.hand_over(self(), {"hi", [read_only: true]}, [])
      assert_received {:"$gen_cast", {:initial_prompt, "hi", [], [read_only: true]}}
    end

    # During a rollout the server can be on the previous release. The rule for
    # `client_request_id` is to deliver without it; for this flag that would run
    # the prompt writable, so the prompt is not delivered at all.
    test "a server that cannot enforce it is not sent the prompt" do
      me = self()
      cannot = fn _node -> false end

      assert PromptDelivery.permitted(me, [read_only: true], cannot) ==
               {:error, :read_only_unavailable}

      # A normal prompt still goes anywhere.
      assert PromptDelivery.permitted(me, [client_request_id: "a"], cannot) == :ok
      assert PromptDelivery.permitted(me, [read_only: false], cannot) == :ok

      assert PromptDelivery.understands_read_only?(node())
      refute PromptDelivery.understands_read_only?(:"nobody@nowhere.invalid")
    end
  end

  describe "an owner on the previous release" do
    test "a turn admitted without the flag it was asked for is failed, not run" do
      conv = insert_conversation(%{status: "running"})
      turn = insert_turn(conv, status: "running")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ReadOnly.confirm_admitted(conv, turn, read_only: true) ==
                   {:error, :read_only_unavailable}
        end)

      refute log =~ "error"
      assert Repo.get!(Turn, turn.id).status == "failed"

      assert Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.stage == "turn" and &1.state == "failed" and
                   &1.data =~ "read_only_unavailable")
             )
    end

    test "a turn admitted as asked is left alone" do
      conv = insert_conversation(%{status: "running"})
      ro = insert_turn(conv, status: "running", read_only: true)
      normal = insert_turn(conv, status: "running")

      assert {:ok, ^conv, ^ro} = ReadOnly.confirm_admitted(conv, ro, read_only: true)
      assert {:ok, ^conv, ^normal} = ReadOnly.confirm_admitted(conv, normal, [])
    end
  end
end
