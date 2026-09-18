defmodule Fountain.Conversations.AttachTest do
  # `sandbox_id` on start_conversation (ADR 0023 gate 3): a conversation on a
  # machine the caller already has, under the attach rules.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Launch

  setup do
    user = insert_active_user()
    env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id,
        vault_id: nil
      )

    first = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, env: env, vault: vault, agent: agent, sandbox: sandbox, first: first}
  end

  defp attach(ctx, extra \\ %{}) do
    Launch.start_conversation(
      Map.merge(
        %{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id, "sandbox_id" => ctx.sandbox.id},
        extra
      )
    )
  end

  test "opens an idle conversation on the same machine, with no server", ctx do
    assert {:ok, conv} = attach(ctx)
    assert conv.sandbox_id == ctx.sandbox.id
    assert conv.status == "idle"
    assert conv.agent_id == ctx.agent.id
    assert conv.runtime == "claude"
    assert Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, conv.id) == [ctx.first.id]
  end

  test "a foreign or malformed sandbox reads as not found", ctx do
    foreign = insert_sandbox(user_id: insert_active_user().id, status: "ready")

    assert {:error, :sandbox_not_found} = attach(ctx, %{"sandbox_id" => foreign.id})
    assert {:error, :sandbox_not_found} = attach(ctx, %{"sandbox_id" => "not-a-uuid"})
    assert {:error, :sandbox_not_found} = attach(ctx, %{"sandbox_id" => Ecto.UUID.generate()})
  end

  for status <- ["pending", "starting", "terminated", "failed"] do
    test "a #{status} machine refuses a conversation", ctx do
      status = unquote(status)
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: status})
      assert {:error, {:sandbox_not_attachable, ^status}} = attach(ctx)
    end
  end

  test "a suspended machine takes a conversation", ctx do
    {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "suspended"})
    assert {:ok, _} = attach(ctx)
  end

  test "the launch must name the identity the disk was built from", ctx do
    # A vault the machine was not built with.
    assert {:error, :sandbox_identity_mismatch} = attach(ctx, %{"vault_id" => ctx.vault.id})

    # An environment override that is not the machine's.
    other_env = insert_env(user_id: ctx.user.id)
    assert {:error, :sandbox_identity_mismatch} = attach(ctx, %{"environment_id" => other_env.id})

    # Naming the machine's own environment explicitly is the same identity.
    assert {:ok, _} = attach(ctx, %{"environment_id" => ctx.env.id})

    # Another agent, even the same user's.
    other_agent =
      insert_agent(user_id: ctx.user.id, runtime: "claude", environment_id: ctx.env.id)

    assert {:error, :sandbox_identity_mismatch} = attach(ctx, %{"agent_id" => other_agent.id})
  end

  test "an agent whose runtime changed since gets a new machine, not this one", ctx do
    agent = ctx.agent |> Ecto.Changeset.change(runtime: "codex") |> Repo.update!()
    assert {:error, :sandbox_runtime_mismatch} = attach(%{ctx | agent: agent})
  end

  test "with a prompt, a one-at-a-time runtime's machine refuses while a turn runs", ctx do
    agent = ctx.agent |> Ecto.Changeset.change(runtime: "opencode") |> Repo.update!()
    {:ok, _} = Conversations.update_conversation(ctx.first, %{runtime: "opencode"})
    ctx = %{ctx | agent: agent}

    insert_turn(ctx.first, %{
      status: "running",
      prompt: "busy",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    assert {:error, :sandbox_at_capacity} = attach(ctx, %{"prompt" => "hello"})
    # Without a prompt nothing runs yet, so nothing is refused.
    assert {:ok, _} = attach(ctx)
  end

  test "a fresh launch stamps the identity on the sandbox it provisions", ctx do
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    assert {:ok, conv} =
             Launch.start_conversation(%{
               "agent_id" => ctx.agent.id,
               "user_id" => ctx.user.id,
               "vault_id" => ctx.vault.id
             })

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.agent_id == ctx.agent.id
    assert sandbox.vault_id == ctx.vault.id
    assert sandbox.environment_id == ctx.env.id
  end

  describe "listing" do
    test "sandboxes are tenant-scoped, newest first, with their conversations", ctx do
      _foreign = insert_sandbox(user_id: insert_active_user().id, status: "ready")
      {:ok, second} = attach(ctx)

      assert [%{id: id, conversations: convs}] = Conversations.list_sandboxes(ctx.user.id)
      assert id == ctx.sandbox.id
      # Both rows land in the same second, so the order between them is not
      # pinned; the membership is.
      assert Enum.sort(Enum.map(convs, & &1.id)) == Enum.sort([second.id, ctx.first.id])

      assert [] = Conversations.list_sandboxes(ctx.user.id, status: ["terminated"])
      assert [_] = Conversations.list_sandboxes(ctx.user.id, status: ["ready", "suspended"])
    end

    test "get_sandbox is scoped and tolerant of a bad id", ctx do
      assert %{id: id} = Conversations.get_sandbox(ctx.sandbox.id, ctx.user.id)
      assert id == ctx.sandbox.id
      assert nil == Conversations.get_sandbox(ctx.sandbox.id, insert_active_user().id)
      assert nil == Conversations.get_sandbox("nope", ctx.user.id)
    end
  end
end
