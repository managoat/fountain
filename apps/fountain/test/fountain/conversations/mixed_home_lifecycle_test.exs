defmodule Fountain.Conversations.MixedHomeLifecycleTest do
  @moduledoc """
  The lifecycle of a mixed-runtime home (ADR 0023, amended 2026-09-26, #2516):
  one agent's home with a conversation of an agent of another runtime attached
  to it by `sandbox_id`. The row's `agent_id` and `runtime` stay the home's.

  The machine is put together here directly rather than through the attach
  that makes one (#2515, `guest_attach_test.exs`): a persistent home of the
  host agent, a conversation of the host on it and one of the guest. The default is a claude home with a
  codex guest; `mixed_home/2` builds the other way round.
  """
  use Fountain.ConversationServerCase

  alias Fountain.{Agents, Crypto, InferenceCredentials}
  alias Fountain.Conversations.{InferenceBinding, Provisioning, Reapply, Termination, Wake}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Machines.Machine

  setup do
    stub_happy_sprite()
    user = insert_verified_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)

    # A codex agent resolves its inference from a named set; the harness
    # answers the account's own credentials with none.
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.create_set(user.id, "Codex")
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-codex")

    Map.merge(
      %{user: user, env: env, dek: dek, set: set},
      mixed_home(%{user: user, env: env, set: set}, {"claude", "codex"})
    )
  end

  defp agent_of(ctx, "codex") do
    insert_agent(
      user_id: ctx.user.id,
      runtime: "codex",
      model: "openai/gpt-5",
      environment_id: ctx.env.id,
      inference_credential_id: ctx.set.id
    )
  end

  defp agent_of(ctx, runtime),
    do: insert_agent(user_id: ctx.user.id, runtime: runtime, environment_id: ctx.env.id)

  defp mixed_home(ctx, {host_runtime, guest_runtime}) do
    host_agent = agent_of(ctx, host_runtime)
    guest_agent = agent_of(ctx, guest_runtime)

    home =
      insert_sandbox(
        user_id: ctx.user.id,
        agent_id: host_agent.id,
        environment_id: ctx.env.id,
        mode: "persistent",
        runtime: host_runtime,
        status: "ready",
        provider: "sprites"
      )

    host =
      insert_conversation(user_id: ctx.user.id, agent: host_agent, sandbox: home, status: "idle")

    guest =
      insert_conversation(user_id: ctx.user.id, agent: guest_agent, sandbox: home, status: "idle")

    %{host_agent: host_agent, guest_agent: guest_agent, home: home, host: host, guest: guest}
  end

  defp status(conv), do: Conversations._unsafe_get_conversation!(conv.id).status
  defp reload(conv), do: Conversations._unsafe_get_conversation!(conv.id)

  # The sprite is gone, and a woken conversation's server is a stand-in.
  defp sprite_gone do
    stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)
    stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end)
    stub(ConversationServer, :queue_initial_prompt, fn _pid, _prompt, _images -> :ok end)
  end

  # The replacement a wake reserved, built: the provision ran and the sprite
  # answers again.
  defp built(sandbox_id) do
    sandbox = Conversations._unsafe_get_sandbox!(sandbox_id)
    {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
    stub(Managoat.Sandbox.Sprites, :get, fn _h -> {:ok, %{status: :running, raw: %{}}} end)
    sandbox
  end

  defp observe_runtime_preparation do
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
  end

  defp start_live(conv) do
    {pid, _ref, settled} = start_server(reload(conv))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    settled
  end

  defp source(ctx, credential) do
    {:ok, set} = InferenceCredentials.create_set(ctx.user.id, "Set #{credential}")
    {:ok, set} = InferenceCredentials.put_credential_in(set, ctx.dek, :openai_api_key, credential)

    {:ok, source, _} =
      InferenceCredentials.resolve(ctx.user.id, "openai/gpt-5", "codex",
        credential_set_id: set.id
      )

    source
  end

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

    test "a guest that cannot be ended stops the deletion", ctx do
      stub(Termination, :terminate_conversation, fn _id, _opts -> {:error, :boom} end)

      assert {:error, :boom} = Agents.delete_agent(ctx.guest_agent)

      # The agent is still there, and so is the guest's pointer to it.
      assert Agents.get_agent(ctx.guest_agent.id, ctx.user.id)
      assert reload(ctx.guest).agent_id == ctx.guest_agent.id
    end

    test "a guest whose server exited mid-call is ended through the no-server path", ctx do
      # `call_server/2` answers `:not_running` for a server that went between
      # `whereis/1` and the call, with the conversation still live.
      stub(Termination, :terminate_conversation, fn id, opts ->
        Mimic.call_original(Termination, :terminate_conversation, [id, opts])
      end)

      expect(Termination, :terminate_conversation, fn _id, _opts -> {:error, :not_running} end)

      assert {:ok, _} = Agents.delete_agent(ctx.guest_agent)
      assert status(ctx.guest) == "terminated"
      assert Repo.reload!(ctx.home).status == "ready"
    end

    test "a guest still live after the retry stops the deletion", ctx do
      stub(Termination, :terminate_conversation, fn _id, _opts -> {:error, :not_running} end)

      assert {:error, :not_running} = Agents.delete_agent(ctx.guest_agent)
      assert Agents.get_agent(ctx.guest_agent.id, ctx.user.id)
      assert status(ctx.guest) == "idle"
    end

    test "a guest whose row ended though its machine answered an error does not", ctx do
      stub(Termination, :terminate_conversation, fn id, _opts ->
        {:ok, _} = Conversations.update_conversation(reload(%{id: id}), %{status: "terminated"})
        {:error, :sandbox_unavailable}
      end)

      assert {:ok, _} = Agents.delete_agent(ctx.guest_agent)
      assert status(ctx.guest) == "terminated"
      refute Agents.get_agent(ctx.guest_agent.id, ctx.user.id)
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

    test "a guest alone on the home still cannot take it over", ctx do
      {:ok, _} = Conversations.update_conversation(ctx.host, %{status: "terminated"})

      assert {:error, {:rebuild_required, :guest}} =
               Reapply.update_identity(ctx.guest, ctx.guest_agent, ctx.env.id, nil)

      assert Reapply.explain(:guest) =~ "another agent's home"

      home = Repo.reload!(ctx.home)
      assert {home.agent_id, home.runtime} == {ctx.host_agent.id, "claude"}
    end

    test "the home's own conversation still refreshes once the guest has gone", ctx do
      {:ok, _} = Conversations.update_conversation(ctx.guest, %{status: "terminated"})
      assert :ok = Reapply.update_identity(ctx.host, ctx.host_agent, ctx.env.id, nil)
    end
  end

  describe "re-provision" do
    test "a guest that wakes first on a dead home rebuilds the home, not one of its own",
         ctx do
      sprite_gone()

      assert {:ok, woken} = Wake.wake_conversation(ctx.guest.id, "hello")

      replacement = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
      refute replacement.id == ctx.home.id
      assert replacement.mode == "persistent"
      assert replacement.agent_id == ctx.host_agent.id
      assert replacement.runtime == "claude"
      assert Repo.reload!(ctx.home).status == "terminated"

      # The host followed onto it, and the guest's conversation keeps its own
      # runtime for the provision its server runs.
      assert reload(ctx.host).sandbox_id == replacement.id
      assert woken.runtime == "codex"
    end

    test "a guest that no longer declares the home's environment rebuilds its own", ctx do
      # A teammate rebinding moved the guest's environment after it attached.
      other_env = insert_env(user_id: ctx.user.id)
      {:ok, _} = Conversations.update_conversation(ctx.guest, %{environment_id: other_env.id})
      sprite_gone()

      assert {:ok, woken} = Wake.wake_conversation(ctx.guest.id, "hello")

      replacement = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
      assert {replacement.agent_id, replacement.runtime} == {ctx.guest_agent.id, "codex"}
      assert replacement.environment_id == other_env.id
      # The host did not follow onto a machine of another identity.
      assert reload(ctx.host).sandbox_id == ctx.home.id
    end

    test "a codex guest waking on a home its host rebuilt prepares its own runtime", ctx do
      # The host wakes first: the home is rebuilt from the host's agent, and
      # the guest follows onto it with its runtime session cleared.
      sprite_gone()
      assert {:ok, woken} = Wake.wake_conversation(ctx.host.id, "hello")
      rebuilt = built(woken.sandbox_id)
      assert reload(ctx.guest).sandbox_id == rebuilt.id

      observe_runtime_preparation()
      # The reattach arm, not a provision: the machine exists.
      reject(Managoat.Sandbox.Sprites, :create, 2)

      assert start_live(ctx.guest) == :alive

      assert_received {:skills, "codex"}
      assert_received {:instructions, "codex"}
      assert_received {:runtime_prepared, "codex"}
      refute_received {:runtime_prepared, "claude"}

      # Its Codex auth is the machine's first: a claude conversation built it,
      # so nothing had written one.
      assert reload(ctx.guest).inference_source["set_id"] == ctx.set.id
      assert Repo.reload!(rebuilt).codex_inference_source
      assert Repo.reload!(rebuilt).status == "ready"
    end

    test "a codex host waking on its home a claude guest rebuilt binds its auth", ctx do
      mixed = mixed_home(ctx, {"codex", "claude"})

      # The claude guest wakes first and rebuilds the codex home, under the
      # home's label; its own provision binds no Codex auth.
      sprite_gone()
      assert {:ok, woken} = Wake.wake_conversation(mixed.guest.id, "hello")
      rebuilt = built(woken.sandbox_id)
      assert {rebuilt.agent_id, rebuilt.runtime} == {mixed.host_agent.id, "codex"}
      assert reload(mixed.host).sandbox_id == rebuilt.id
      assert is_nil(rebuilt.codex_inference_source)

      observe_runtime_preparation()
      reject(Managoat.Sandbox.Sprites, :create, 2)

      assert start_live(mixed.host) == :alive
      assert_received {:runtime_prepared, "codex"}
      assert Repo.reload!(rebuilt).codex_inference_source
    end
  end

  describe "a guest whose binding left the home's environment or vault (#2515)" do
    setup ctx do
      # A teammate rebinding moved the guest's environment after it attached.
      other_env = insert_env(user_id: ctx.user.id)
      {:ok, _} = Conversations.update_conversation(ctx.guest, %{environment_id: other_env.id})
      %{other_env: other_env}
    end

    test "a wake moves it to a machine of its own and leaves the live home alone", ctx do
      stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end)
      stub(ConversationServer, :queue_initial_prompt, fn _pid, _prompt, _images -> :ok end)
      # Nothing is written to the home's disk.
      reject(Managoat.Sandbox.Sprites, :write_file, 4)

      assert {:ok, woken} = Wake.wake_conversation(ctx.guest.id, "hello")

      moved = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
      refute moved.id == ctx.home.id
      assert moved.mode == "ephemeral"
      assert {moved.agent_id, moved.runtime} == {ctx.guest_agent.id, "codex"}
      assert moved.environment_id == ctx.other_env.id

      home = Repo.reload!(ctx.home)
      assert home.status == "ready"
      assert is_nil(home.transition)
      assert reload(ctx.host).sandbox_id == ctx.home.id
    end

    test "a server that reaches a reattach anyway stops before it writes the disk", ctx do
      # A claude guest on a codex home, so no Codex bind stands in the way.
      mixed = mixed_home(ctx, {"codex", "claude"})

      {:ok, _} =
        Conversations.update_conversation(mixed.guest, %{environment_id: ctx.other_env.id})

      reject(Managoat.Sandbox.Sprites, :write_file, 4)
      reject(Provisioning, :write_env_file, 2)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, ref, _settled} = start_server(reload(mixed.guest))
          assert assert_stopped(ref) == :normal
        end)

      assert log =~ "not reattaching to sandbox #{mixed.home.id}"
      assert reload(mixed.guest).sandbox_id == mixed.home.id
    end

    test "one that still matches reattaches as before", ctx do
      {:ok, _} =
        Conversations.update_conversation(reload(ctx.guest), %{environment_id: ctx.env.id})

      refute Fountain.Machines.Binding.guest_moved?(ctx.home, reload(ctx.guest), ctx.guest_agent)
    end
  end

  describe "a deleted conversation of another runtime (#2515)" do
    test "the home still redacts its credential and still refuses a second codex agent", ctx do
      # The guest ran here with a stored source, then its row was deleted.
      {:ok, _} =
        Conversations.update_conversation(ctx.guest, %{
          inference_source: Source.dump(source(ctx, "sk-deleted-guest"))
        })

      {:ok, _} = Conversations.delete_conversation(reload(ctx.guest))
      assert is_nil(Conversations._unsafe_get_conversation(ctx.guest.id))

      [descriptor] = Repo.reload!(ctx.home).departed_conversations
      assert descriptor["runtime"] == "codex"
      assert descriptor["agent_id"] == ctx.guest_agent.id
      assert descriptor["environment_id"] == ctx.env.id
      refute Jason.encode!(descriptor) =~ "sk-deleted-guest"

      on_exit(fn -> Fountain.Conversations.Redaction.delete(ctx.host.id) end)
      assert Fountain.Conversations.CotenantSecrets.register(ctx.host.id, ctx.home.id) == :mixed
      assert "sk-deleted-guest" in Fountain.Conversations.Redaction.lookup(ctx.host.id)

      other_codex = agent_of(ctx, "codex")

      assert {:error, :sandbox_identity_mismatch} =
               Fountain.Machines.Binding.attachable(
                 Repo.reload!(ctx.home),
                 other_codex,
                 nil,
                 ctx.env.id
               )

      # The agent that left the files may come back to them.
      assert :ok =
               Fountain.Machines.Binding.attachable(
                 Repo.reload!(ctx.home),
                 ctx.guest_agent,
                 nil,
                 ctx.env.id
               )
    end

    test "a deleted host conversation is still redacted for the guest", ctx do
      {:ok, _} = Conversations.delete_conversation(reload(ctx.host))
      [descriptor] = Repo.reload!(ctx.home).departed_conversations
      assert descriptor["runtime"] == "claude"
      assert Fountain.Conversations.CotenantSecrets.register(ctx.guest.id, ctx.home.id) == :mixed
      Fountain.Conversations.Redaction.delete(ctx.guest.id)
    end

    test "one descriptor per source, and none once the machine is gone", ctx do
      second =
        insert_conversation(user_id: ctx.user.id, agent: ctx.guest_agent, sandbox: ctx.home)

      {:ok, _} = Conversations.delete_conversation(reload(ctx.guest))
      {:ok, _} = Conversations.delete_conversation(reload(second))
      assert [_one] = Repo.reload!(ctx.home).departed_conversations

      {:ok, _} = update_sandbox(Repo.reload!(ctx.home), %{status: "terminated"})
      {:ok, _} = Conversations.delete_conversation(reload(ctx.host))
      assert [_still_one] = Repo.reload!(ctx.home).departed_conversations
    end

    test "deleting the machine or its owner cascades without the trigger getting in the way",
         ctx do
      Repo.delete!(Repo.reload!(ctx.home))
      assert is_nil(Conversations._unsafe_get_conversation(ctx.guest.id))

      other = mixed_home(ctx, {"claude", "codex"})
      Repo.delete!(ctx.user)
      assert is_nil(Conversations._unsafe_get_conversation(other.guest.id))
    end
  end

  describe "the Codex auth binding on a machine another runtime built" do
    # A built claude machine, as a claude conversation's reservation leaves it,
    # with a codex conversation on it.
    defp claude_built(ctx, peer_homes?) do
      machine =
        insert_sandbox(
          user_id: ctx.user.id,
          agent_id: ctx.host_agent.id,
          runtime: "claude",
          status: "ready",
          provider: "sprites"
        )
        |> Ecto.Changeset.change(codex_peer_homes: peer_homes?)
        |> Repo.update!()

      conv = insert_conversation(user_id: ctx.user.id, agent: ctx.guest_agent, sandbox: machine)
      {machine, conv}
    end

    test "takes the first API key and refuses a second", ctx do
      {machine, first} = claude_built(ctx, true)
      assert :ok = InferenceBinding.reserve(first, source(ctx, "sk-one"))
      assert Repo.reload!(machine).codex_inference_source

      second = insert_conversation(user_id: ctx.user.id, agent: ctx.guest_agent, sandbox: machine)

      assert {:error, :codex_inference_conflict} =
               InferenceBinding.reserve(second, source(ctx, "sk-two"))
    end

    test "refuses when a retired codex conversation has been on it", ctx do
      {machine, conv} = claude_built(ctx, true)

      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.guest_agent,
        sandbox: machine,
        status: "terminated",
        inference_source: Source.dump(source(ctx, "sk-retired"))
      )

      assert {:error, :codex_inference_conflict} =
               InferenceBinding.reserve(conv, source(ctx, "sk-new"))

      assert is_nil(Repo.reload!(machine).codex_inference_source)
    end

    test "keeps the old rule on a built machine its reservation did not stamp", ctx do
      # A machine from before the stamp: its auth file may predate the record.
      {_machine, conv} = claude_built(ctx, false)

      assert {:error, :codex_inference_conflict} =
               InferenceBinding.reserve(conv, source(ctx, "sk-one"))
    end
  end

  describe "the reservation's stamp" do
    test "only a machine a claude conversation builds carries it" do
      user = insert_verified_user()

      reserve = fn builder ->
        {:ok, sandbox} =
          Fountain.Machines.Provision.reserve(%{
            machine_name: "stamp-#{System.unique_integer([:positive])}",
            status: "pending",
            provider: "sprites",
            user_id: user.id,
            runtime: "codex",
            builder_runtime: builder
          })

        sandbox.codex_peer_homes
      end

      assert reserve.("claude")
      refute reserve.("codex")
      # The command runtime can run `codex-acp` or `codex login` itself.
      refute reserve.("acp")
      refute reserve.("opencode")
      refute reserve.(nil)
    end
  end
end
