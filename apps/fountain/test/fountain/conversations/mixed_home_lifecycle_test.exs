defmodule Fountain.Conversations.MixedHomeLifecycleTest do
  @moduledoc """
  The lifecycle of a mixed-runtime home (ADR 0023, amended 2026-09-26, #2516):
  a claude agent's home with a codex agent's conversation attached to it by
  `sandbox_id`. The row's `agent_id` and `runtime` stay the home's.

  The attach that makes one is not built yet (#2515), so the machine is put
  together here directly: a persistent home of the host agent, a conversation
  of the host on it and one of the guest.
  """
  use Fountain.ConversationServerCase

  alias Fountain.{Agents, Crypto, InferenceCredentials}
  alias Fountain.Conversations.{Provisioning, Reapply, Wake}
  alias Fountain.Machines.Machine

  setup do
    stub_happy_sprite()
    user = insert_verified_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)

    # The codex guest resolves its inference from a named set; the harness
    # answers the account's own credentials with none.
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.create_set(user.id, "Codex")
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-guest")

    host_agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    guest_agent =
      insert_agent(
        user_id: user.id,
        runtime: "codex",
        model: "openai/gpt-5",
        environment_id: env.id,
        inference_credential_id: set.id
      )

    home =
      insert_sandbox(
        user_id: user.id,
        agent_id: host_agent.id,
        environment_id: env.id,
        mode: "persistent",
        runtime: "claude",
        status: "ready",
        provider: "sprites"
      )

    host = insert_conversation(user_id: user.id, agent: host_agent, sandbox: home, status: "idle")

    guest =
      insert_conversation(user_id: user.id, agent: guest_agent, sandbox: home, status: "idle")

    %{
      user: user,
      env: env,
      host_agent: host_agent,
      guest_agent: guest_agent,
      home: home,
      host: host,
      guest: guest
    }
  end

  defp status(conv), do: Conversations._unsafe_get_conversation!(conv.id).status

  describe "deleting an agent" do
    test "the home's agent: the home is destroyed and the guest ends with it", ctx do
      test = self()
      stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

      assert {:ok, _} = Agents.delete_agent(ctx.host_agent)

      assert_received :destroyed
      assert Repo.reload!(ctx.home).status == "terminated"
      assert status(ctx.host) == "terminated"
      assert status(ctx.guest) == "terminated"
    end

    test "the guest's agent: its conversation ends and the home stays", ctx do
      test = self()
      stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

      assert {:ok, _} = Agents.delete_agent(ctx.guest_agent, actor: "user:#{ctx.user.id}")

      assert status(ctx.guest) == "terminated"
      assert status(ctx.host) == "idle"

      home = Repo.reload!(ctx.home)
      assert home.status == "ready"
      assert home.agent_id == ctx.host_agent.id
      assert home.runtime == "claude"
      assert is_nil(home.transition)
      refute_received :destroyed

      # Still the host agent's home: the next launch of it lands here.
      assert %{id: id} =
               Conversations._unsafe_find_home(
                 ctx.user.id,
                 ctx.host_agent.id,
                 ctx.env.id,
                 nil,
                 "claude"
               )

      assert id == ctx.home.id

      # Recorded against the person who deleted the agent.
      assert Repo.get_by(Fountain.Audit.Event,
               action: "conversation.terminated",
               resource_id: ctx.guest.id,
               actor: "user:#{ctx.user.id}"
             )
    end

    test "the guest's agent, with the host gone: the home is still kept", ctx do
      # The last live conversation on a home ending keeps the home — the
      # guest's agent going must not read as "the machine's agent went".
      {:ok, _} = Conversations.update_conversation(ctx.host, %{status: "terminated"})
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {:ok, _} = Agents.delete_agent(ctx.guest_agent)

      assert status(ctx.guest) == "terminated"
      assert Repo.reload!(ctx.home).status == "ready"
    end
  end

  describe "reapply" do
    test "stays refused while the other agent's conversation shares the machine", ctx do
      # The guest's own selection moves the machine's identity to its agent,
      # and the host still declares the home's.
      assert {:error, {:rebuild_required, :shared_sandbox}} =
               Reapply.update_identity(ctx.guest, ctx.guest_agent, ctx.env.id, nil)

      assert {:error, {:rebuild_required, :shared_sandbox}} =
               Machine.retarget(ctx.home.id, %{agent_id: ctx.guest_agent.id},
                 conversation_id: ctx.guest.id
               )

      # And the other way round: the host cannot move the home to another
      # agent from under its guest.
      other = insert_agent(user_id: ctx.user.id, runtime: "claude", environment_id: ctx.env.id)

      assert {:error, {:rebuild_required, :shared_sandbox}} =
               Machine.retarget(ctx.home.id, %{agent_id: other.id}, conversation_id: ctx.host.id)

      assert Repo.reload!(ctx.home).agent_id == ctx.host_agent.id
    end
  end

  describe "re-provision" do
    test "a guest that wakes first on a dead home rebuilds the home, not one of its own",
         ctx do
      # The sprite is gone.
      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)
      stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end)
      stub(ConversationServer, :queue_initial_prompt, fn _pid, _prompt, _images -> :ok end)

      assert {:ok, woken} = Wake.wake_conversation(ctx.guest.id, "hello")

      replacement = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
      refute replacement.id == ctx.home.id
      assert replacement.mode == "persistent"
      assert replacement.agent_id == ctx.host_agent.id
      assert replacement.runtime == "claude"
      assert Repo.reload!(ctx.home).status == "terminated"

      # The host followed onto it, and the guest's conversation keeps its own
      # runtime for the provision its server runs.
      assert Conversations._unsafe_get_conversation!(ctx.host.id).sandbox_id == replacement.id
      assert woken.runtime == "codex"
    end

    test "a guest waking on a re-provisioned home prepares its own runtime", ctx do
      # The home was rebuilt from the host's agent: a fresh `ready` claude
      # machine that no codex conversation has run on, with the guest moved
      # onto it by the replacement and its runtime session cleared.
      {:ok, _} = update_sandbox(ctx.home, %{status: "terminated"})

      rebuilt =
        insert_sandbox(
          user_id: ctx.user.id,
          agent_id: ctx.host_agent.id,
          environment_id: ctx.env.id,
          mode: "persistent",
          runtime: "claude",
          status: "ready",
          provider: "sprites"
        )

      Repo.update_all(
        from(c in Fountain.Conversations.Conversation,
          where: c.id in ^[ctx.host.id, ctx.guest.id]
        ),
        set: [sandbox_id: rebuilt.id, runtime_session_id: nil]
      )

      test = self()

      stub(Fountain.SandboxSkills, :reconcile, fn _h, runtime, _skills, _previous ->
        send(test, {:skills, runtime})
        :ok
      end)

      stub(Provisioning, :write_instructions, fn _h, runtime, _agent ->
        send(test, {:instructions, runtime})
        :ok
      end)

      stub(Provisioning, :prepare_runtime_sprite, fn _h, runtime, _mod, _a, _env, _src, _u ->
        send(test, {:runtime_prepared, runtime})
        :ok
      end)

      # The reattach arm, not a provision: the machine exists.
      reject(Managoat.Sandbox.Sprites, :create, 2)

      guest = Conversations._unsafe_get_conversation!(ctx.guest.id)
      {pid, _ref, :alive} = start_server(guest)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_received {:skills, "codex"}
      assert_received {:instructions, "codex"}
      assert_received {:runtime_prepared, "codex"}
      refute_received {:runtime_prepared, "claude"}

      # Its Codex auth is the machine's first: nothing had written one.
      assert Repo.reload!(guest).inference_source["set_id"] ==
               ctx.guest_agent.inference_credential_id

      assert Repo.reload!(rebuilt).codex_inference_source
      assert Repo.reload!(rebuilt).status == "ready"
    end
  end
end
