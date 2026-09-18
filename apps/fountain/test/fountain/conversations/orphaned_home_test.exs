defmodule Fountain.Conversations.OrphanedHomeTest do
  # #1084: a home is keyed on (user, agent, environment, vault). When the key
  # moves out from under it — the agent's environment changes, or the
  # environment or vault the key names is deleted — the home is retired rather
  # than left `ready` under an identity nothing looks up any more.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Environments
  alias Fountain.Vaults

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)
    other_env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        environment_id: env.id,
        sandbox_mode: "persistent"
      )

    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    {:ok, user: user, env: env, other_env: other_env, vault: vault, agent: agent}
  end

  defp home(ctx, overrides \\ []) do
    attrs =
      [
        user_id: ctx.user.id,
        status: "ready",
        mode: "persistent",
        agent_id: ctx.agent.id,
        environment_id: ctx.env.id,
        provider: "sprites"
      ]
      |> Keyword.merge(overrides)

    insert_sandbox(attrs)
  end

  defp expect_destroy do
    test = self()
    stub(Managoat.Sandbox.Sprites, :destroy, fn h -> send(test, {:destroyed, h.name}) && :ok end)
  end

  describe "the agent's environment changes" do
    test "the home built on the old environment is destroyed and retired", ctx do
      expect_destroy()
      old = home(ctx)

      assert {:ok, agent} =
               Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})

      assert agent.environment_id == ctx.other_env.id

      assert_received {:destroyed, name}
      assert name == old.machine_name
      assert Conversations._unsafe_get_sandbox!(old.id).status == "terminated"
    end

    test "the conversations on it are kept, and their next prompt has no session to resume",
         ctx do
      expect_destroy()
      old = home(ctx)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: old,
          status: "idle",
          runtime_session_id: "sess-1"
        )

      assert {:ok, _} = Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})

      reloaded = Conversations._unsafe_get_conversation!(conv.id)
      assert reloaded.status == "idle"
      assert is_nil(reloaded.runtime_session_id)
    end

    test "each transcript says the environment moved, not that the owner reset it", ctx do
      expect_destroy()
      old = home(ctx)

      conv =
        insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: old, status: "idle")

      assert {:ok, _} = Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})

      assert [event] =
               conv.id
               |> Conversations._unsafe_list_log_events()
               |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))

      assert %{"event" => "reset", "reason" => "environment_changed", "message" => message} =
               Jason.decode!(event.data)

      assert message =~ "different environment"
    end

    test "a home already on the new environment is left alone", ctx do
      expect_destroy()
      keeper = home(ctx, environment_id: ctx.other_env.id)

      assert {:ok, _} = Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})

      refute_received {:destroyed, _}
      assert Conversations._unsafe_get_sandbox!(keeper.id).status == "ready"
    end

    test "an agent losing its environment orphans the home that had one", ctx do
      expect_destroy()
      old = home(ctx)

      assert {:ok, agent} = Agents.update_agent(ctx.agent, %{"environment_id" => nil})
      assert is_nil(agent.environment_id)
      assert Conversations._unsafe_get_sandbox!(old.id).status == "terminated"
    end

    test "an update that does not touch the environment leaves the home standing", ctx do
      expect_destroy()
      standing = home(ctx)

      assert {:ok, _} = Agents.update_agent(ctx.agent, %{"name" => "renamed"})

      refute_received {:destroyed, _}
      assert Conversations._unsafe_get_sandbox!(standing.id).status == "ready"
    end

    test "an ephemeral sandbox of the same agent is not a home and is untouched", ctx do
      expect_destroy()

      ephemeral =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          mode: "ephemeral",
          agent_id: ctx.agent.id,
          environment_id: ctx.env.id
        )

      assert {:ok, _} = Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})

      refute_received {:destroyed, _}
      assert Conversations._unsafe_get_sandbox!(ephemeral.id).status == "ready"
    end

    test "refused mid-turn, and nothing is written", ctx do
      standing = home(ctx)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: standing,
          status: "running"
        )

      insert_turn(conv, status: "running")
      before = Agents.list_agent_versions(ctx.agent.id, ctx.user.id)

      assert {:error, :sandbox_mid_turn} =
               Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})

      # The refusal is the whole answer: the agent did not move, the machine
      # is still there, and the change left no version behind.
      assert Agents._unsafe_get_agent(ctx.agent.id).environment_id == ctx.env.id
      assert Conversations._unsafe_get_sandbox!(standing.id).status == "ready"
      assert Agents.list_agent_versions(ctx.agent.id, ctx.user.id) == before
    end

    test "an invalid change is still a changeset error, not a mid-turn refusal", ctx do
      standing = home(ctx)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: standing,
          status: "running"
        )

      insert_turn(conv, status: "running")

      # A foreign environment id: the update cannot commit, so nothing is
      # orphaned and the mid-turn check must not pre-empt the real error.
      foreign = insert_env().id

      assert {:error, %Ecto.Changeset{} = cs} =
               Agents.update_agent(ctx.agent, %{"environment_id" => foreign})

      assert %{environment_id: ["does not exist"]} = errors_on(cs)
    end

    test "the audit row names the reason", ctx do
      expect_destroy()
      old = home(ctx)

      assert {:ok, _} =
               Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id},
                 actor: "api"
               )

      assert [row] =
               Fountain.Audit.list_for_user(ctx.user.id)
               |> Enum.filter(&(&1.action == "sandbox.reset"))

      assert row.resource_id == old.id
      assert row.actor == "api"
      assert row.metadata["reason"] == "environment_changed"
    end
  end

  describe "the environment is deleted" do
    test "the home is retired instead of silently becoming the no-environment home", ctx do
      expect_destroy()
      old = home(ctx)

      assert {:ok, _} = Environments.delete_environment(ctx.env)

      assert_received {:destroyed, _}
      retired = Conversations._unsafe_get_sandbox!(old.id)
      assert retired.status == "terminated"

      # The FK nilify still lands, which is exactly why the row had to be
      # retired first: a live row here would be the no-environment home.
      assert is_nil(retired.environment_id)

      assert is_nil(
               Conversations._unsafe_find_home(
                 ctx.user.id,
                 ctx.agent.id,
                 nil,
                 nil,
                 ctx.agent.runtime
               )
             )
    end

    test "a delete that would collide with an existing no-environment home succeeds", ctx do
      expect_destroy()
      # Before #1084 the ON DELETE SET NULL collided with
      # sandboxes_home_identity_index (NULLS NOT DISTINCT) and the delete
      # raised Ecto.ConstraintError — the owner could not delete at all.
      no_env = home(ctx, environment_id: nil)
      keyed = home(ctx)

      assert {:ok, _} = Environments.delete_environment(ctx.env)

      assert Conversations._unsafe_get_sandbox!(keyed.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(no_env.id).status == "ready"
    end

    test "refused mid-turn, and the environment stays", ctx do
      standing = home(ctx)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: standing,
          status: "running"
        )

      insert_turn(conv, status: "running")

      assert {:error, :sandbox_mid_turn} = Environments.delete_environment(ctx.env)
      assert Environments.get_environment(ctx.env.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(standing.id).status == "ready"
    end

    test "an environment with no home deletes as before", ctx do
      assert {:ok, _} = Environments.delete_environment(ctx.other_env)
      refute Environments.get_environment(ctx.other_env.id, ctx.user.id)
    end
  end

  describe "the vault is deleted" do
    test "the home is retired instead of becoming the no-vault home", ctx do
      expect_destroy()
      old = home(ctx, vault_id: ctx.vault.id)

      assert {:ok, _} = Vaults.delete_vault(ctx.vault)

      assert_received {:destroyed, _}
      retired = Conversations._unsafe_get_sandbox!(old.id)
      assert retired.status == "terminated"
      assert is_nil(retired.vault_id)

      # The point of retiring it: a launch that asks for no vault must not
      # land on a disk holding the deleted vault's secrets.
      assert is_nil(
               Conversations._unsafe_find_home(
                 ctx.user.id,
                 ctx.agent.id,
                 ctx.env.id,
                 nil,
                 ctx.agent.runtime
               )
             )
    end

    test "a delete that would collide with an existing no-vault home succeeds", ctx do
      expect_destroy()
      no_vault = home(ctx)
      keyed = home(ctx, vault_id: ctx.vault.id)

      assert {:ok, _} = Vaults.delete_vault(ctx.vault)

      assert Conversations._unsafe_get_sandbox!(keyed.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(no_vault.id).status == "ready"
    end

    test "the transcript names the vault, and the audit row carries the reason", ctx do
      expect_destroy()
      old = home(ctx, vault_id: ctx.vault.id)

      conv =
        insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: old, status: "idle")

      assert {:ok, _} = Vaults.delete_vault(ctx.vault, actor: "api")

      assert [event] =
               conv.id
               |> Conversations._unsafe_list_log_events()
               |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))

      assert %{"reason" => "vault_deleted"} = Jason.decode!(event.data)

      assert [row] =
               Fountain.Audit.list_for_user(ctx.user.id)
               |> Enum.filter(&(&1.action == "sandbox.reset"))

      assert row.metadata["reason"] == "vault_deleted"
    end

    test "refused mid-turn, and the vault stays", ctx do
      standing = home(ctx, vault_id: ctx.vault.id)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: standing,
          status: "running"
        )

      insert_turn(conv, status: "running")

      assert {:error, :sandbox_mid_turn} = Vaults.delete_vault(ctx.vault)
      assert Vaults.get_vault(ctx.vault.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(standing.id).status == "ready"
    end

    test "a vault with no home deletes as before", ctx do
      assert {:ok, _} = Vaults.delete_vault(ctx.vault)
      refute Vaults.get_vault(ctx.vault.id, ctx.user.id)
    end
  end

  describe "a provider that cannot destroy" do
    test "an uncertain reset stays fenced and counted after the identity changes", ctx do
      stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> {:error, :boom} end)
      old = home(ctx)

      assert {:ok, _} = Agents.update_agent(ctx.agent, %{"environment_id" => ctx.other_env.id})
      held = Conversations._unsafe_get_sandbox!(old.id)
      assert held.status == "ready"
      refute is_nil(held.reset_requested_at)
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
      assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(old)
    end
  end
end
