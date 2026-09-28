defmodule Fountain.Conversations.ReadOnlyTurnTest do
  @moduledoc """
  Read-only turns, enforced at the adapter boundary (#2533).

  A real `ConversationServer` runs a claude conversation whose adapter command
  is stubbed onto `test/fixtures/acp_write_agent.exs`, and every spawn runs the
  argv the server built (`FixtureAcpProcess.stub_spawn_argv/2`). So the
  wrapper a read-only turn's adapter starts behind, the env it exports and the
  managed policy it writes are the real ones, and the fixture honours that
  policy the way Claude Code does. A write it is allowed to make lands on the
  disk; one it is refused does not.
  """

  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{Blocks, PromptDelivery, ReadOnly}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    stub_happy_sprite()

    fixture = Fountain.FixtureAcpProcess.fixture_path("acp_write_agent.exs")

    Mimic.stub(Fountain.RuntimeDispatch, :command, fn _runtime, _agent ->
      {"elixir", [fixture]}
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _h, _r, _e ->
      :ok
    end)

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    %{home: home, files: Path.join(tmp_dir, "checkout")}
  end

  defp launch(ctx, prompt, prompt_opts, extra_env \\ []) do
    File.mkdir_p!(ctx.files)
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(agent: agent, user_id: user.id)

    :ok = Fountain.FixtureAcpProcess.stub_spawn_argv(self(), [{"HOME", ctx.home} | extra_env])

    {pid, _mon, :alive} = start_server(conv, initial_prompt: prompt, prompt_opts: prompt_opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {conv, pid}
  end

  defp path(ctx, name), do: Path.join(ctx.files, name)

  defp await_turns(conv_id, count, timeout \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_turns(conv_id, count, deadline, nil)
  end

  defp await_turns(conv_id, count, deadline, last) do
    turns = Conversations._unsafe_list_turns(conv_id)
    conv = Conversations._unsafe_get_conversation!(conv_id)

    cond do
      length(turns) == count and Enum.all?(turns, &(&1.status == "completed")) and
          conv.status == "idle" ->
        Enum.sort_by(turns, & &1.turn_number)

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{count} completed turns; last was #{inspect(last || turns)}")

      true ->
        Process.sleep(50)
        await_turns(conv_id, count, deadline, turns)
    end
  end

  defp texts(conv_id, turn_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.stream == "acp" and &1.turn_id == turn_id))
    |> Enum.flat_map(&Blocks.for_event/1)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join(& &1.body)
  end

  defp started_event(conv_id, turn_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.find(&(&1.stage == "turn" and &1.state == "started" and &1.turn_id == turn_id))
  end

  defp assert_spawn(read_only?) do
    assert_receive {:spawned, cmd, args, env}, 20_000
    argv = [cmd | args]

    if read_only? do
      assert "fountain-read-only" in argv
      assert ReadOnly.managed_settings() in argv
      assert {"FOUNTAIN_READ_ONLY", "1"} in env
    else
      refute "fountain-read-only" in argv
      refute {"FOUNTAIN_READ_ONLY", "1"} in env
    end
  end

  defp prompt(pid, text, opts), do: PromptDelivery.deliver(pid, text, [], opts)

  describe "one conversation, normal and read-only turns" do
    test "a read-only turn is refused its write inside the agent, and turns either side of it write",
         ctx do
      {conv, pid} = launch(ctx, "write #{path(ctx, "one")}", [])
      assert_spawn(false)
      [one] = await_turns(conv.id, 1)
      assert File.read!(path(ctx, "one")) == "written"
      refute one.read_only

      assert :ok = prompt(pid, "write #{path(ctx, "two")}", read_only: true)

      # A fresh adapter under the managed policy: the idle writable one is
      # never asked to run a read-only turn.
      assert_spawn(true)
      [_, two] = await_turns(conv.id, 2)

      assert two.read_only
      refute File.exists?(path(ctx, "two"))

      # Refused by the agent itself, and still answered, from the same session:
      # the resumed agent knows the prompt before it.
      assert texts(conv.id, two.id) =~ "could not write: denied by policy; context: 1 earlier"
      assert started_event(conv.id, two.id).data =~ ~s("read_only":true)
      refute started_event(conv.id, one.id).data =~ "read_only"

      settings =
        Path.join([ctx.home, ".fountain", "read-only", "claude", "managed-settings.json"])

      assert File.read!(settings) == ReadOnly.managed_settings()

      assert :ok = prompt(pid, "write #{path(ctx, "three")}", [])

      # And a writable adapter again for the turn after it.
      assert_spawn(false)
      [_, _, three] = await_turns(conv.id, 3)

      refute three.read_only
      assert File.read!(path(ctx, "three")) == "written"
      assert texts(conv.id, three.id) =~ "context: 2 earlier"
    end

    test "consecutive read-only turns share one read-only adapter", ctx do
      {conv, pid} = launch(ctx, "write #{path(ctx, "one")}", read_only: true)
      assert_spawn(true)
      [_] = await_turns(conv.id, 1)

      assert :ok = prompt(pid, "write #{path(ctx, "two")}", read_only: true)
      [_, two] = await_turns(conv.id, 2)
      refute_received {:spawned, _, _, _}

      assert two.read_only
      refute File.exists?(path(ctx, "one"))
      refute File.exists?(path(ctx, "two"))
    end
  end

  describe "the permission policy is the second wall" do
    test "an agent that ignores the managed policy is refused by the peer's clamp", ctx do
      {conv, _pid} = launch(ctx, "ignore-policy write #{path(ctx, "one")}", read_only: true)
      assert_spawn(true)
      [one] = await_turns(conv.id, 1)

      assert one.read_only
      refute File.exists?(path(ctx, "one"))
      assert texts(conv.id, one.id) =~ "could not write: refused"
    end

    test "the clamp leaves reads alone and denies every other kind" do
      turn = %Fountain.Conversations.Turn{read_only: true}
      policy = ReadOnly.permission_policy(%{"default" => "auto_allow", "edit" => "ask"}, turn)

      for kind <- ~w(read search think fetch),
          do: assert(Managoat.ACP.Permissions.verdict_for(policy, kind) == "auto_allow")

      for kind <- ~w(edit delete move execute other switch_mode),
          do: assert(Managoat.ACP.Permissions.verdict_for(policy, kind) == "auto_deny")

      # Never wider than the agent's own: an `ask` on reads stays an ask.
      narrowed = ReadOnly.permission_policy(%{"read" => "ask"}, turn)
      assert Managoat.ACP.Permissions.verdict_for(narrowed, "read") == "ask"

      # A normal turn's policy is untouched.
      normal = %Fountain.Conversations.Turn{read_only: false}
      assert ReadOnly.permission_policy(%{"edit" => "ask"}, normal) == %{"edit" => "ask"}
    end
  end

  describe "the flag survives what relaunches a turn" do
    test "an adapter that crashes before a byte is relaunched read-only", ctx do
      marker = Path.join(ctx.home, "crashed")

      {conv, _pid} =
        launch(ctx, "write #{path(ctx, "one")}", [read_only: true], [
          {"FIXTURE_CRASH_ONCE_MARKER", marker}
        ])

      # The first process dies of SIGSEGV (#2402); the relaunch is the same
      # read-only turn, wrapped the same way.
      assert_spawn(true)
      assert_spawn(true)
      [one] = await_turns(conv.id, 1)

      assert File.exists?(marker)
      assert one.read_only
      refute File.exists?(path(ctx, "one"))
      assert texts(conv.id, one.id) =~ "denied by policy"
    end
  end

  describe "a runtime that cannot enforce it" do
    test "a read-only prompt on codex is refused before a turn exists", ctx do
      File.mkdir_p!(ctx.files)
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "codex")
      conv = insert_conversation(agent: agent, user_id: user.id)
      :ok = Fountain.FixtureAcpProcess.stub_spawn_argv(self(), [{"HOME", ctx.home}])

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:error, {:read_only_unsupported, "codex"}} =
               prompt(pid, "write #{path(ctx, "one")}", read_only: true)

      assert Conversations._unsafe_list_turns(conv.id) == []
      refute_received {:spawned, _, _, _}

      assert Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.stage == "turn" and &1.state == "failed" and
                   &1.data =~ "read_only_unsupported")
             )
    end
  end
end
