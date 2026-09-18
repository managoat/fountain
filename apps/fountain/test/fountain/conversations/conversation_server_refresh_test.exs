defmodule Fountain.Conversations.ConversationServerRefreshTest do
  @moduledoc """
  `refresh_configuration/2`, and the revision that stops a server starting a
  turn on a selection it has not read (#1565).
  """

  use Fountain.ConversationServerCase

  alias Fountain.Environments
  alias Fountain.Conversations.Reapply

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "pending",
        agent_id: agent.id,
        environment_id: env.id
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        runtime: "claude",
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  test "with no server registered, the public entry point says so", ctx do
    # Nothing else in this file reaches `refresh_configuration/2`: the tests
    # below call the handler on a pid, and the context tests replace the whole
    # function with Mimic. So the `whereis/1` half had no coverage at all, and
    # a change to what it answers was invisible to the suite.
    #
    # This harness's servers are deliberately outside Horde (see
    # `ConversationServerCase.start_server/2`), so the registry never finds one
    # and this is the real production answer for an idle conversation whose
    # server has stopped. It has to be distinguishable from a server that read
    # the selection, because no file was rewritten here.
    assert {:ok, :no_server} =
             Fountain.Conversations.ConversationServer.refresh_configuration(ctx.conv.id)

    assert {:ok, :no_server} =
             Fountain.Conversations.ConversationServer.refresh_configuration(ctx.conv.id, 7)
  end

  test "an idle server re-applies the row and keeps its machine", ctx do
    stub_happy_sprite()
    test = self()
    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

    {pid, _ref, :alive} = start_server(ctx.conv)
    assert {:ok, :reloaded} = GenServer.call(pid, :refresh_configuration)

    # The machine is the whole point of the operation: it stays, and so does
    # everything the agent put on its disk.
    refute_received :destroyed
    assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).status == "ready"
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a delayed notification for the revision already loaded is a no-op", ctx do
    stub_happy_sprite()
    {pid, _ref, :alive} = start_server(ctx.conv)

    revision = :sys.get_state(pid).configuration_revision
    assert {:ok, :reloaded} = GenServer.call(pid, {:refresh_configuration, revision})
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a server with a running turn refuses", ctx do
    stub_happy_sprite()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

    {pid, _monitor, :alive} = start_server(ctx.conv, initial_prompt: "first")
    assert {:error, :conversation_busy} = GenServer.call(pid, :refresh_configuration)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a server holding no machine has nothing to do", ctx do
    stub_happy_sprite()
    {pid, _ref, :alive} = start_server(ctx.conv)
    :sys.replace_state(pid, fn state -> %{state | handle: nil} end)

    assert {:ok, :no_machine} = GenServer.call(pid, :refresh_configuration)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "a sleeping conversation reconciles its skills on the next wake", ctx do
    stub_happy_sprite()

    {:ok, _} =
      update_sandbox(ctx.sandbox, %{
        status: "suspended",
        build_fingerprint: Fountain.Conversations.Reapply.fingerprint(ctx.env)
      })

    {:ok, conv} = Conversations.update_conversation(ctx.conv, %{status: "idle"})

    skills = [%{"name" => "fresh", "content" => "Updated skill"}]
    {:ok, _} = Fountain.Agents.update_agent(ctx.agent, %{skills: skills})
    test = self()

    Mimic.expect(Fountain.SandboxSkills, :reconcile, fn _handle, "claude", ^skills, _previous ->
      send(test, :skills_reconciled)
      :ok
    end)

    assert {:ok, updated} = Reapply.reapply_conversation(conv, %{})
    {pid, _, :alive} = start_server(updated)

    assert_received :skills_reconciled
    assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).applied_skills == skills
    assert :sys.get_state(pid).configuration_revision == updated.configuration_revision
    GenServer.stop(pid)
  end

  test "a prompt reloads configuration when the refresh notification was missed", ctx do
    stub_happy_sprite()
    {pid, _, :alive} = start_server(ctx.conv)

    # The harness server is deliberately outside the registry, so a reapply can
    # commit while it is alive without any notification reaching it.
    {:ok, conv} = Conversations.update_conversation(ctx.conv, %{status: "idle"})

    {:ok, _} =
      Environments.update_environment(ctx.env, %{env_vars: %{"REAPPLY_MARKER" => "fresh"}})

    test = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, opts ->
      send(test, {:spawned, opts[:env]})
      {:error, {:unavailable, :test_finished}}
    end)

    assert {:ok, updated} = Reapply.reapply_conversation(conv, %{})
    assert :sys.get_state(pid).configuration_revision == 0

    assert :ok = GenServer.call(pid, {:send_prompt, "after reapply", []})
    state = :sys.get_state(pid)
    assert state.configuration_revision == updated.configuration_revision

    assert_received {:spawned, env}
    assert {"REAPPLY_MARKER", "fresh"} in env
    assert [turn] = Conversations._unsafe_list_turns(conv.id)
    assert turn.prompt == "after reapply"
  end
end
