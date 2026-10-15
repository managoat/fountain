defmodule Fountain.Conversations.ConversationServerIdentityTest do
  # Per-process identity (ADR 0023 gate 1): the conversation a process belongs
  # to travels with the process, never with the disk. The shared env file
  # carries environment and vault values only; the callback token and the
  # conversation id reach the adapter as process env; and the detachable
  # session is tagged so a reattach after a deploy binds to *this*
  # conversation's process rather than the head of the sandbox's list.
  use Fountain.ConversationServerCase

  alias Managoat.Sandbox.Session

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, env_vars: %{"FROM_ENVIRONMENT" => "yes"})
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)
    {:ok, user: user, agent: agent, env: env}
  end

  defp stub_turn_boundary do
    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
    ref
  end

  describe "a fresh provision" do
    test "none launches the real conversation server without a callback credential", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox_api_access: "none")
      test = self()
      stub_happy_sprite()
      stub_turn_boundary()

      Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, env ->
        send(test, {:none_env_file, env})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "review local files")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:none_env_file, file_env}, 2_000
      assert_receive {:spawned, _cmd, _args, opts}, 2_000

      for env <- [file_env, Keyword.fetch!(opts, :env)] do
        refute Enum.any?(env, fn {key, _} -> key == "MANAGOAT_TOKEN" end)
      end

      state = :sys.get_state(pid)
      assert state.callback_token == nil
      assert state.callback_api_key_id == nil
      assert Fountain.Accounts.list_api_keys(user.id) == []
    end

    test "keeps the identity off the disk and on the process", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, env ->
        send(test, {:env_file, env})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:env_file, file_env}, 2_000
      file_keys = Enum.map(file_env, fn {k, _} -> k end)

      # The file is the machine's: environment values, no conversation.
      assert "FROM_ENVIRONMENT" in file_keys
      refute "MANAGOAT_TOKEN" in file_keys
      refute "MANAGOAT_CONVERSATION_ID" in file_keys
      refute "FOUNTAIN_TOKEN" in file_keys
      refute "FOUNTAIN_CONVERSATION_ID" in file_keys
      refute "TRACEPARENT" in file_keys

      # The machine's own id is machine-scoped, so it may sit beside the
      # environment values on disk (ADR 0023: a child onto this sandbox).
      assert {"MANAGOAT_SANDBOX_ID", conv.sandbox_id} in file_env

      # The process is the conversation's: identity as env, and the session
      # tagged on its own command line.
      assert_receive {:spawned, cmd, args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)
      assert {"MANAGOAT_CONVERSATION_ID", conv.id} in spawn_env
      assert {"MANAGOAT_SANDBOX_ID", conv.sandbox_id} in spawn_env
      # and under the names before ADR 0082, for the deprecation window
      assert {"FOUNTAIN_CONVERSATION_ID", conv.id} in spawn_env
      assert {"FOUNTAIN_SANDBOX_ID", conv.sandbox_id} in spawn_env
      assert Enum.any?(spawn_env, &match?({"MANAGOAT_TOKEN", token} when is_binary(token), &1))
      assert {"FROM_ENVIRONMENT", "yes"} in spawn_env

      assert cmd == "env"

      assert [
               "MANAGOAT_CONVERSATION_ID=" <> tag,
               "FOUNTAIN_CONVERSATION_ID=" <> tag,
               "claude-agent-acp" | _
             ] =
               args

      assert tag == conv.id
    end
  end

  describe "a reattach after a deploy" do
    # A `ready` sandbox with a `running` ACP turn is what a server finds after
    # a restart. The prompt id makes the attach a real one (#772).
    defp reattach_fixture(%{user: user, agent: agent} = ctx) do
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      conv =
        insert_conversation(
          agent: agent,
          user_id: user.id,
          sandbox: sandbox,
          status: "running",
          runtime_session_id: "sess_live",
          sandbox_api_access: Map.get(ctx, :sandbox_api_access, "owner")
        )

      turn =
        insert_turn(conv, %{
          status: "running",
          prompt: "long task",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second),
          acp_prompt_id: 4
        })

      {conv, turn}
    end

    defp tagged(id, conv_id) do
      %Session{id: id, command: "env MANAGOAT_CONVERSATION_ID=#{conv_id} claude-agent-acp"}
    end

    defp reattach_outcomes(conv_id) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.filter(&(&1.kind == "stage" and &1.stage == "reattach"))
      |> Enum.map(&Jason.decode!(&1.data))
    end

    test "none remains credential-free when a real server reattaches after restart", ctx do
      {conv, _turn} = reattach_fixture(Map.put(ctx, :sandbox_api_access, "none"))
      stub_happy_sprite()
      ref = stub_turn_boundary()
      test = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _ ->
        {:ok, [tagged("none-session", conv.id)]}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _, id, _ ->
        send(test, {:none_attached, id})
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:none_attached, "none-session"}, 2_000
      state = :sys.get_state(pid)
      assert state.callback_token == nil
      assert state.callback_api_key_id == nil
      assert Fountain.Accounts.list_api_keys(ctx.user.id) == []
    end

    test "binds to the session tagged with this conversation, not the head", ctx do
      {conv, _turn} = reattach_fixture(ctx)

      other_conv =
        insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: conv.sandbox)

      stub_happy_sprite()
      ref = stub_turn_boundary()
      test = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _h ->
        {:ok, [tagged("theirs", other_conv.id), tagged("ours", conv.id)]}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _h, id, _opts ->
        send(test, {:attached, id})
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:attached, "ours"}, 2_000
      refute_received {:attached, "theirs"}
      assert is_pid(:sys.get_state(pid).acp_peer)

      assert Enum.any?(reattach_outcomes(conv.id), fn d ->
               d["outcome"] == "session_attached" and d["session_id"] == "ours" and
                 d["matched_by"] == "tag"
             end)
    end

    for identity <- [:tag, :process_env] do
      test "reaps older #{identity} adapters while preserving the selected turn and other owners",
           ctx do
        {conv, turn} = reattach_fixture(ctx)
        other = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: conv.sandbox)
        test = self()
        current_ref = make_ref()
        old_ref = make_ref()
        stub_happy_sprite()
        stub_turn_boundary()

        old = %{tagged("101", conv.id) | created_at: ~U[2026-09-01 10:00:00Z]}
        current = %{tagged("102", conv.id) | created_at: ~U[2026-09-01 10:05:00Z]}

        [old, current] =
          if unquote(identity) == :process_env do
            Enum.map([old, current], &%{&1 | command: "claude-agent-acp"})
          else
            [old, current]
          end

        sessions = [
          tagged("theirs", other.id),
          old,
          current,
          %Session{id: "103", command: "claude-agent-acp"}
        ]

        Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _ -> {:ok, sessions} end)

        Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, args, _opts ->
          if "fountain-session-identity" in args do
            {:ok, "101 #{conv.id}\n102 #{conv.id}\n103 unknown\n", 0}
          else
            {:ok, "", 0}
          end
        end)

        Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _h, id, _opts ->
          send(test, {:attached, id})
          ref = if id == "101", do: old_ref, else: current_ref
          {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
        end)

        Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn command ->
          send(test, {:closed_stdin, command.ref})
          :ok
        end)

        Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn command ->
          send(test, {:stopped_command, command.ref})
          :ok
        end)

        {pid, _mon, :alive} = start_server(conv)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        state = :sys.get_state(pid)

        assert_received {:attached, "101"}
        assert_received {:closed_stdin, ^old_ref}
        assert_received {:stopped_command, ^old_ref}
        assert_received {:attached, "102"}
        refute_received {:attached, "theirs"}
        refute_received {:attached, "103"}
        refute_received {:closed_stdin, ^current_ref}
        refute_received {:stopped_command, ^current_ref}
        assert state.current_command_ref == current_ref
        assert state.current_turn.id == turn.id
        assert is_pid(state.acp_peer)
        assert Repo.reload!(turn).status == "running"
        assert Repo.reload!(conv).runtime_session_id == "sess_live"
        assert [persisted] = Conversations._unsafe_list_turns(conv.id)
        assert persisted.id == turn.id

        assert Enum.any?(reattach_outcomes(conv.id), fn event ->
                 event["session_id"] == "102" and
                   event["matched_by"] == Atom.to_string(unquote(identity))
               end)
      end
    end

    test "never takes a session tagged for another conversation", ctx do
      {conv, turn} = reattach_fixture(ctx)

      other_conv =
        insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: conv.sandbox)

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      test = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _h ->
        {:ok, [tagged("theirs", other_conv.id)]}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _h, id, _opts ->
        send(test, {:attached, id})
        {:error, :should_not_be_called}
      end)

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      _ = :sys.get_state(pid)

      refute_received {:attached, _}
      assert [%{id: turn_id, status: "interrupted"}] = Conversations._unsafe_list_turns(conv.id)
      assert turn_id == turn.id
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert Enum.any?(reattach_outcomes(conv.id), fn d ->
               d["outcome"] == "turn_orphaned" and d["reason"] == "no_active_session"
             end)

      # The turn's own end, on the stage a client waits on (#2529): an orphaned
      # turn is not left for the client to infer from a `reattach` event.
      assert [ended] =
               conv.id
               |> Conversations._unsafe_list_log_events()
               |> Enum.filter(&(&1.kind == "stage" and &1.stage == "turn"))

      assert ended.state == "interrupted"
      assert ended.turn_id == turn.id
      assert %{"reason" => "no_active_session"} = Jason.decode!(ended.data)
    end

    test "orphans an untagged session rather than guessing its conversation", ctx do
      {conv, _turn} = reattach_fixture(ctx)

      stub_happy_sprite()
      ref = stub_turn_boundary()
      test = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _h ->
        {:ok, [%Session{id: "legacy", command: "claude-agent-acp"}]}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _h, id, _opts ->
        send(test, {:attached, id})
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      refute_received {:attached, "legacy"}

      assert Enum.any?(reattach_outcomes(conv.id), fn d ->
               d["outcome"] == "turn_orphaned" and d["reason"] == "no_active_session"
             end)
    end
  end
end
