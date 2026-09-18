defmodule Fountain.Conversations.ConversationReapplyTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.Reapply
  alias Fountain.Conversations.Launch

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    old_env = insert_env(user_id: user.id)
    old_vault = insert_vault(user_id: user.id)
    new_vault = insert_vault(user_id: user.id)

    # Same build inputs as old_env, so selecting it needs no rebuild. Only
    # the variables differ, and those reach the machine on the next spawn.
    sibling_env =
      insert_env(
        user_id: user.id,
        packages: old_env.packages,
        repositories: old_env.repositories,
        setup_script: old_env.setup_script,
        env_vars: %{"WHO" => "sibling"}
      )

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        environment_id: old_env.id,
        allowed_environment_ids: [old_env.id, sibling_env.id],
        allowed_vault_ids: [old_vault.id, new_vault.id]
      )

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "ephemeral",
        agent_id: agent.id,
        runtime: agent.runtime,
        environment_id: old_env.id,
        vault_id: old_vault.id,
        build_fingerprint: Reapply.fingerprint(old_env)
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        agent_version_id: Agents._unsafe_current_version_id(agent.id),
        sandbox: sandbox,
        vault_id: old_vault.id,
        runtime_session_id: "session-before-reapply",
        status: "idle",
        title: "Keep this thread"
      )

    {:ok,
     user: user,
     old_env: old_env,
     sibling_env: sibling_env,
     old_vault: old_vault,
     new_vault: new_vault,
     agent: agent,
     sandbox: sandbox,
     conv: conv}
  end

  describe "applying a selection to the machine that is already there" do
    test "keeps the conversation, the transcript and the machine", ctx do
      turn = insert_turn(ctx.conv, status: "completed", prompt: "remember this")

      assert {:ok, updated} =
               Reapply.reapply_conversation(ctx.conv, %{},
                 actor: "api",
                 request_ip: "10.0.0.1"
               )

      assert updated.id == ctx.conv.id
      assert updated.title == "Keep this thread"
      # The machine is the point: reapply does not move the conversation off
      # it, so whatever the agent has on disk is still there.
      assert updated.sandbox_id == ctx.sandbox.id
      assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).status == "ready"
      assert Conversations._unsafe_list_turns(updated.id) |> Enum.map(& &1.id) == [turn.id]

      # Nothing clears it here. The machine survives, so the runtime session
      # on its disk is still resumable until the server drops the connection.
      assert updated.runtime_session_id == "session-before-reapply"
      assert updated.configuration_revision == 1

      # No server runs in this test, and none is stubbed, so this is the
      # acceptance-criterion-one case: an idle conversation whose server has
      # stopped. Nothing on the sprite was rewritten, so `done` would claim a
      # machine holds the selection when none has read it. The selection still
      # stands and the next wake applies it, which is what `failed` says here.
      [stage] =
        Conversations._unsafe_list_log_events(updated.id)
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "configuration"))

      assert stage.state == "failed"
      assert Jason.decode!(stage.data)["reason"] == "no_server"
    end

    test "tells the live server to apply it", ctx do
      test = self()

      stub(Fountain.Conversations.ConversationServer, :refresh_configuration, fn id, revision ->
        send(test, {:refreshed, id, revision})
        {:ok, :reloaded}
      end)

      assert {:ok, updated} = Reapply.reapply_conversation(ctx.conv, %{})
      assert_received {:refreshed, id, revision}
      assert id == ctx.conv.id
      assert revision == updated.configuration_revision

      # Only a live server that read the selection earns `done`. Its pair is
      # the `failed` case below: the same committed row, nothing rewritten.
      [stage] =
        Conversations._unsafe_list_log_events(ctx.conv.id)
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "configuration"))

      assert stage.state == "done"
    end

    test "a machine that has not caught up is an event, not a failed call", ctx do
      Mimic.expect(Fountain.Conversations.ConversationServer, :refresh_configuration, fn _, _ ->
        {:error, :conversation_busy}
      end)

      # The commit already happened, so the caller is not told it did not.
      assert {:ok, updated} = Reapply.reapply_conversation(ctx.conv, %{})
      assert updated.configuration_revision == 1

      # The part the previous shape of this test never looked at: the row moved
      # while the call reported an error, which is what made the error a lie.
      reread = Conversations._unsafe_get_conversation!(ctx.conv.id)
      assert reread.configuration_revision == 1
      assert reread.vault_id == updated.vault_id

      # No `done` over a server that never reloaded. `failed` says the
      # selection stands and the machine is behind, which is the true state.
      [stage] =
        Conversations._unsafe_list_log_events(ctx.conv.id)
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "configuration"))

      assert stage.state == "failed"
    end

    test "audits the change, naming the fields that moved", ctx do
      assert {:ok, updated} =
               Reapply.reapply_conversation(ctx.conv, %{"vault_id" => ctx.new_vault.id},
                 actor: "api",
                 request_ip: "10.0.0.1"
               )

      [audit] =
        Fountain.Audit.list_for_user(ctx.user.id)
        |> Enum.filter(&(&1.action == "conversation.configuration_reapplied"))

      assert audit.actor == "api"
      assert audit.request_ip == "10.0.0.1"
      assert audit.resource_id == updated.id
      assert audit.metadata["changed_fields"] == ["vault_id"]
      assert audit.metadata["previous"]["vault_id"] == ctx.old_vault.id
      assert audit.metadata["current"]["vault_id"] == ctx.new_vault.id
      assert audit.metadata["configuration_revision"] == 1
    end

    test "records the agent's current version", ctx do
      {:ok, _} = Agents.update_agent(ctx.agent, %{system: "a new persona"})
      newest = Agents._unsafe_current_version_id(ctx.agent.id)
      refute newest == ctx.conv.agent_version_id

      assert {:ok, updated} = Reapply.reapply_conversation(ctx.conv, %{})
      assert updated.agent_version_id == newest
    end

    test "rebinds the Vault, and an explicit null clears it", ctx do
      assert {:ok, updated} =
               Reapply.reapply_conversation(ctx.conv, %{"vault_id" => ctx.new_vault.id})

      assert updated.vault_id == ctx.new_vault.id
      assert updated.sandbox_id == ctx.sandbox.id

      assert {:ok, cleared} = Reapply.reapply_conversation(updated, %{"vault_id" => nil})
      assert cleared.vault_id == nil
    end

    test "rebinds to an environment that builds the machine the same way", ctx do
      assert {:ok, updated} =
               Reapply.reapply_conversation(ctx.conv, %{
                 "environment_id" => ctx.sibling_env.id
               })

      assert updated.environment_id == ctx.sibling_env.id
      assert updated.sandbox_id == ctx.sandbox.id
    end
  end

  describe "a selection that would need the disk rebuilt" do
    test "refuses a runtime change and names it", ctx do
      codex =
        insert_agent(
          user_id: ctx.user.id,
          runtime: "codex",
          environment_id: ctx.old_env.id,
          allowed_vault_ids: [ctx.old_vault.id]
        )

      assert {:error, {:rebuild_required, :runtime}} =
               Reapply.reapply_conversation(ctx.conv, %{"agent_id" => codex.id})

      unchanged = Conversations._unsafe_get_conversation!(ctx.conv.id)
      assert unchanged.agent_id == ctx.agent.id
      assert unchanged.runtime == "claude"
      assert unchanged.configuration_revision == 0
    end

    test "refuses an environment whose build inputs differ, and names the field", ctx do
      rebuilt =
        insert_env(
          user_id: ctx.user.id,
          setup_script: "echo a genuinely different setup",
          packages: ctx.old_env.packages,
          repositories: ctx.old_env.repositories
        )

      {:ok, _} =
        Agents.update_agent(ctx.agent, %{allowed_environment_ids: [ctx.old_env.id, rebuilt.id]})

      conv = Conversations._unsafe_get_conversation!(ctx.conv.id)

      assert {:error, {:rebuild_required, :setup_script}} =
               Reapply.reapply_conversation(conv, %{"environment_id" => rebuilt.id})

      assert Conversations._unsafe_get_conversation!(conv.id).environment_id == nil
    end

    test "refuses a networking change, because egress rules are written once", ctx do
      restricted =
        insert_env(
          user_id: ctx.user.id,
          packages: ctx.old_env.packages,
          repositories: ctx.old_env.repositories,
          setup_script: ctx.old_env.setup_script,
          networking_type: "limited",
          networking_config: %{"allow" => ["example.com"]}
        )

      {:ok, _} =
        Agents.update_agent(ctx.agent, %{
          allowed_environment_ids: [ctx.old_env.id, restricted.id]
        })

      conv = Conversations._unsafe_get_conversation!(ctx.conv.id)

      assert {:error, {:rebuild_required, :networking}} =
               Reapply.reapply_conversation(conv, %{"environment_id" => restricted.id})
    end

    test "refuses to reconfigure a machine other conversations share", ctx do
      home =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          mode: "persistent",
          agent_id: ctx.agent.id,
          environment_id: ctx.old_env.id,
          vault_id: ctx.old_vault.id,
          build_fingerprint: Reapply.fingerprint(ctx.old_env)
        )

      {:ok, conv} = Conversations.update_conversation(ctx.conv, %{sandbox_id: home.id})

      _cotenant =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: home,
          vault_id: ctx.old_vault.id,
          status: "idle"
        )

      # Skills, instructions and .mcp.json are per-machine paths, so changing
      # the vault here would change it for the cotenant too.
      assert {:error, {:rebuild_required, :shared_sandbox}} =
               Reapply.reapply_conversation(conv, %{"vault_id" => ctx.new_vault.id})

      # The refresh its cotenants would want anyway is still allowed.
      assert {:ok, refreshed} = Reapply.reapply_conversation(conv, %{})
      assert refreshed.sandbox_id == home.id
    end
  end

  describe "refusals that change nothing" do
    test "foreign and disallowed resources", ctx do
      other = insert_active_user()
      foreign_agent = insert_agent(user_id: other.id)

      assert {:error, :not_found} =
               Reapply.reapply_conversation(ctx.conv, %{"agent_id" => foreign_agent.id})

      locked_agent =
        insert_agent(
          user_id: ctx.user.id,
          runtime: "claude",
          allowed_vault_ids: [],
          allowed_environment_ids: []
        )

      assert {:error, :vault_not_allowed} =
               Reapply.reapply_conversation(ctx.conv, %{
                 "agent_id" => locked_agent.id,
                 "vault_id" => ctx.new_vault.id
               })

      unchanged = Conversations._unsafe_get_conversation!(ctx.conv.id)
      assert unchanged.agent_id == ctx.agent.id
      assert unchanged.vault_id == ctx.old_vault.id
    end

    test "a running turn", ctx do
      insert_turn(ctx.conv, status: "running")

      assert {:error, :conversation_busy} = Reapply.reapply_conversation(ctx.conv, %{})
      assert Conversations._unsafe_get_conversation!(ctx.conv.id).vault_id == ctx.old_vault.id
    end

    test "a terminated conversation is gone", ctx do
      {:ok, done} = Conversations.update_conversation(ctx.conv, %{status: "terminated"})
      assert {:error, :gone} = Reapply.reapply_conversation(done, %{})
    end

    test "a conversation whose agent was deleted is refused, not crashed", ctx do
      {:ok, orphan} = Conversations.update_conversation(ctx.conv, %{agent_id: nil})

      assert {:error, :no_agent} = Reapply.reapply_conversation(orphan, %{})
    end
  end

  describe "a conversation that has not run a turn yet" do
    test "is reapplicable once its machine is ready", ctx do
      # Nothing writes `idle` until a turn ends, so a conversation created
      # without a prompt sits at `pending` for good. Refusing it made "I
      # picked the wrong agent before I sent anything" unreachable.
      {:ok, promptless} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

      assert {:ok, updated} =
               Reapply.reapply_conversation(promptless, %{"vault_id" => ctx.new_vault.id})

      assert updated.vault_id == ctx.new_vault.id
    end

    test "is refused while its machine is still being built", ctx do
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "starting"})
      {:ok, provisioning} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

      assert {:error, :provisioning} = Reapply.reapply_conversation(provisioning, %{})
    end
  end

  describe "the machine's binding identity" do
    test "attachments use the new sandbox identity", ctx do
      assert {:ok, updated} =
               Reapply.reapply_conversation(ctx.conv, %{"vault_id" => ctx.new_vault.id})

      assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).vault_id == ctx.new_vault.id

      attrs = %{
        "user_id" => ctx.user.id,
        "agent_id" => ctx.agent.id,
        "sandbox_id" => ctx.sandbox.id
      }

      assert {:ok, _} =
               Launch.start_conversation(Map.put(attrs, "vault_id", updated.vault_id))

      assert {:error, :sandbox_identity_mismatch} =
               Launch.start_conversation(Map.put(attrs, "vault_id", ctx.old_vault.id))
    end

    test "a conflicting persistent home rolls back both bindings", ctx do
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{mode: "persistent"})

      insert_sandbox(
        user_id: ctx.user.id,
        mode: "persistent",
        status: "ready",
        agent_id: ctx.agent.id,
        environment_id: ctx.old_env.id,
        vault_id: ctx.new_vault.id
      )

      assert {:error, %Ecto.Changeset{}} =
               Reapply.reapply_conversation(ctx.conv, %{"vault_id" => ctx.new_vault.id})

      assert Conversations._unsafe_get_conversation!(ctx.conv.id).vault_id == ctx.old_vault.id
      assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).vault_id == ctx.old_vault.id
    end

    test "the skills on disk survive a reapply that has not reconciled them", ctx do
      old = [%{"name" => "removed", "content" => "Old instructions"}]
      {:ok, _} = Agents.update_agent(ctx.agent, %{skills: old})

      {:ok, conv} =
        Conversations.update_conversation(ctx.conv, %{
          agent_version_id: Agents._unsafe_current_version_id(ctx.agent.id)
        })

      {:ok, _} = Agents.update_agent(ctx.agent, %{skills: []})
      assert {:ok, _} = Reapply.reapply_conversation(conv, %{})
      assert Conversations._unsafe_get_sandbox!(ctx.sandbox.id).applied_skills == old
    end
  end

  describe "concurrent selections" do
    test "omitted fields use the latest committed selection", ctx do
      assert {:ok, _} =
               Reapply.reapply_conversation(ctx.conv, %{"vault_id" => ctx.new_vault.id})

      # Deliberately the stale `ctx.conv`: the second caller never saw the
      # first one's vault, and must not undo it by omission.
      assert {:ok, updated} =
               Reapply.reapply_conversation(ctx.conv, %{
                 "environment_id" => ctx.sibling_env.id
               })

      assert updated.vault_id == ctx.new_vault.id
      assert updated.environment_id == ctx.sibling_env.id
      assert updated.configuration_revision == 2
    end

    test "a stale server cannot open a turn after a reapply", ctx do
      assert {:ok, updated} = Reapply.reapply_conversation(ctx.conv, %{})

      assert {:error, :configuration_changed} =
               Conversations._unsafe_create_turn_on_sandbox(
                 %{
                   conversation_id: ctx.conv.id,
                   turn_number: 1,
                   prompt: "hello",
                   status: "running"
                 },
                 ctx.sandbox.id,
                 ctx.conv.configuration_revision
               )

      assert Conversations._unsafe_list_turns(ctx.conv.id) == []

      # The same call with the revision the reapply committed is admitted,
      # and then the conversation is busy rather than reapplicable.
      assert {:ok, _conv, _turn} =
               Fountain.Conversations.TurnMachine.open(
                 ctx.conv.id,
                 ctx.sandbox.id,
                 "hello",
                 nil,
                 updated.configuration_revision
               )

      assert {:error, :conversation_busy} = Reapply.reapply_conversation(updated, %{})
    end

    test "a caller with no revision to offer is not checked", ctx do
      assert {:ok, _} = Reapply.reapply_conversation(ctx.conv, %{})

      assert {:ok, _turn} =
               Conversations._unsafe_create_turn_on_sandbox(
                 %{
                   conversation_id: ctx.conv.id,
                   turn_number: 1,
                   prompt: "hello",
                   status: "running"
                 },
                 ctx.sandbox.id
               )
    end
  end
end
