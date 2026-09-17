defmodule Fountain.Conversations.SandboxModeTest do
  # ADR 0023 gate 6: a persistent launch lands on the agent identity's one
  # home, provisioning it on the first launch and attaching on every later
  # one; a home outlives a conversation and dies with its agent.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Agents.Agent
  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Wake

  setup do
    user = insert_active_user()
    # Several homes get provisioned in one test; the cap is not the subject.
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)
    agent = agent |> Ecto.Changeset.change(sandbox_mode: "persistent") |> Repo.update!()
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
    {:ok, user: user, env: env, agent: agent}
  end

  defp launch(ctx, extra \\ %{}) do
    Launch.start_conversation(
      Map.merge(%{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id}, extra)
    )
  end

  test "the agent's mode is validated" do
    user = insert_active_user()

    cs =
      Agent.changeset(%Agent{}, %{
        name: "a",
        model: "anthropic/x",
        runtime: "claude",
        user_id: user.id,
        sandbox_mode: "sometimes"
      })

    assert %{sandbox_mode: ["is invalid"]} = errors_on(cs)
    assert Agent.sandbox_modes() == ["ephemeral", "persistent"]
    assert Sandbox.modes() == ["ephemeral", "persistent"]
  end

  test "the first persistent launch provisions the home, stamped as one", ctx do
    assert {:ok, conv} = launch(ctx)
    home = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert home.mode == "persistent"
    assert home.agent_id == ctx.agent.id
    assert home.environment_id == ctx.env.id
    assert conv.status == "pending"
  end

  test "a second persistent launch lands on the same home once it is ready", ctx do
    {:ok, first} = launch(ctx)

    {:ok, _} =
      Conversations.update_sandbox(Conversations._unsafe_get_sandbox!(first.sandbox_id), %{
        status: "ready"
      })

    assert {:ok, second} = launch(ctx)
    assert second.sandbox_id == first.sandbox_id
    assert second.status == "idle"
    assert Conversations._unsafe_list_cotenant_ids(first.sandbox_id, first.id) == [second.id]
  end

  test "while the home is still provisioning a second launch is told to retry", ctx do
    {:ok, _first} = launch(ctx)
    assert {:error, :provisioning} = launch(ctx)
  end

  test "a different environment or vault is a different home", ctx do
    {:ok, first} = launch(ctx)

    {:ok, _} =
      Conversations.update_sandbox(Conversations._unsafe_get_sandbox!(first.sandbox_id), %{
        status: "ready"
      })

    other_env = insert_env(user_id: ctx.user.id)
    assert {:ok, second} = launch(ctx, %{"environment_id" => other_env.id})
    refute second.sandbox_id == first.sandbox_id
    assert Conversations._unsafe_get_sandbox!(second.sandbox_id).mode == "persistent"

    vault = insert_vault(user_id: ctx.user.id)
    assert {:ok, third} = launch(ctx, %{"vault_id" => vault.id})
    refute third.sandbox_id in [first.sandbox_id, second.sandbox_id]
  end

  test "a launch may ask for the other mode, and an unknown one is refused", ctx do
    assert {:ok, conv} = launch(ctx, %{"sandbox_mode" => "ephemeral"})
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).mode == "ephemeral"
    # An ephemeral launch is never a home, so the next persistent one builds one.
    assert {:ok, other} = launch(ctx)
    refute other.sandbox_id == conv.sandbox_id

    assert {:error, :invalid_sandbox_mode} = launch(ctx, %{"sandbox_mode" => "sometimes"})
  end

  test "the home is single per identity even when two launches race", ctx do
    # Simulate the loser of the race: a home already exists but this launch
    # did not see it and tries to insert its own. The unique index refuses,
    # and the launch lands on the existing home instead.
    {:ok, first} = launch(ctx)
    home = Conversations._unsafe_get_sandbox!(first.sandbox_id)
    {:ok, _} = Conversations.update_sandbox(home, %{status: "ready"})

    assert {:error, changeset} =
             Conversations.create_sandbox(%{
               user_id: ctx.user.id,
               agent_id: ctx.agent.id,
               environment_id: ctx.env.id,
               vault_id: nil,
               mode: "persistent",
               machine_name: "dup",
               status: "pending",
               provider: "sprites"
             })

    assert %{home: [_]} = errors_on(changeset)
  end

  test "terminating a conversation keeps the home", ctx do
    # `_unsafe_sandbox_kept_on_terminate?/2` (dead code, no production caller,
    # deleted with the retarget in #2259) wrapped two predicates: a persistent
    # home is always kept, and anything else is kept only if another live
    # conversation still holds it. Assert each half directly.
    {:ok, conv} = launch(ctx)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).mode == "persistent"

    ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")
    alone = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ephemeral)
    refute Fountain.Machines.Binding.held_by_other?(ephemeral.id, alone.id)
  end

  test "a wake onto a fresh sandbox keeps the home a home", ctx do
    {:ok, conv} = launch(ctx)
    old = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, _} = Conversations.update_sandbox(old, %{status: "ready"})
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

    assert {:ok, woken} = Wake.wake_conversation(conv.id)
    refute woken.sandbox_id == old.id
    assert Conversations._unsafe_get_sandbox!(woken.sandbox_id).mode == "persistent"
    assert Repo.reload(old).status == "terminated"
    # And the new one is the home now.
    assert %{id: id} = Conversations._unsafe_find_home(ctx.user.id, ctx.agent.id, ctx.env.id, nil)
    assert id == woken.sandbox_id
  end

  test "deleting the agent destroys its homes", ctx do
    {:ok, conv} = launch(ctx)
    home = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, _} = Conversations.update_sandbox(home, %{status: "ready"})
    test = self()
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

    assert {:ok, _} = Agents.delete_agent(ctx.agent)
    assert_received :destroyed
    assert Repo.reload(home).status == "terminated"
    assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
  end
end
