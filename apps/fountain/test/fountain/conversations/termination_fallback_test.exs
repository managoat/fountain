defmodule Fountain.Conversations.TerminationFallbackTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Audit
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Termination

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    assert ConversationServer.whereis(conv.id) == nil
    %{user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  # Two things changed here at ADR 0058 stage 5, and the assertions moved with
  # them. The dead-server path now **destroys the machine**, where before it
  # fenced the row, wrote it terminal and left the sprite for the reaper — so
  # the moment this test observes the fence from is the provider destroy
  # rather than a stubbed `Conversations.update_sandbox/2`, which this path no
  # longer calls at all. And the completed destroy records its own
  # `sandbox.destroyed` beside the fence's intent.
  test "fences attachments, destroys the machine and attributes both events", ctx do
    machine_name = ctx.sandbox.machine_name

    expect(Managoat.Sandbox, :destroy, fn %Managoat.Sandbox.Handle{name: ^machine_name} ->
      refute Repo.in_transaction?()
      fenced = Repo.reload!(ctx.sandbox)
      assert fenced.reset_requested_at
      assert fenced.teardown_requested_at
      # Durable intent, stamped before the provider call and before the row is
      # terminal: a reader sees what is being done to the machine (ADR 0058).
      assert fenced.transition == "destroying"
      assert fenced.status == "ready"
      assert {:error, :sandbox_reset_pending} = attach(ctx)
      :ok
    end)

    assert :ok = terminate(ctx)
    retired = Repo.reload!(ctx.sandbox)
    assert retired.status == "terminated"
    assert retired.terminated_at
    assert is_nil(retired.transition)
    assert Repo.reload!(ctx.conv).status == "terminated"

    assert [intent] = events(ctx, "sandbox.teardown_requested")
    assert intent.actor == "ui"
    assert intent.request_ip == "192.0.2.5"
    assert intent.metadata["reason"] == "conversation_terminated"

    assert [destroyed] = events(ctx, "sandbox.destroyed")
    assert destroyed.actor == "ui"
    assert destroyed.request_ip == "192.0.2.5"
    assert destroyed.metadata["reason"] == "terminated"
    assert destroyed.metadata["provider"] == "sprites"
    assert destroyed.metadata["sprite_name"] == machine_name

    assert [_] = events(ctx, "conversation.terminated")
  end

  # Rewritten at ADR 0058 stage 6a. This used to assert that an attach landing
  # between the lease claim and the fence *won* — it kept the machine, and the
  # destroy then found a cotenant and stood down. Stage 6a moves the point at
  # which a machine stops taking new work from the fence back to the lease
  # claim, which is where the ADR puts it ("the owner is a lease first"): an
  # attach that meets a live lease is refused with `:sandbox_unavailable`, 503
  # and retryable, and the destroy it raced runs to completion.
  #
  # The window this closes is the one #2307 constraint 2 names. What the caller
  # loses is a machine it would have saved by a few milliseconds' luck; what it
  # gets is a retry that lands on a settled machine instead of a binding to one
  # somebody is halfway through destroying. Stage 8 makes the same refusal
  # structural, when `attach` itself goes through the owner.
  test "an attachment that arrives after the lease is claimed is refused", ctx do
    expect(Lifecycle, :fence_sandbox_for_teardown, fn sandbox, opts ->
      assert {:error, :sandbox_unavailable} = attach(ctx)
      Mimic.call_original(Lifecycle, :fence_sandbox_for_teardown, [sandbox, opts])
    end)

    expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.conv).status == "terminated"

    # No cotenant stood in its way, so the machine is gone — where before the
    # refused attach would have been a cotenant and kept it `ready`.
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert [_] = events(ctx, "sandbox.teardown_requested")
    assert [_] = events(ctx, "sandbox.destroyed")
  end

  test "a fence refusal leaves the machine available and records no completed termination", ctx do
    expect(Lifecycle, :fence_sandbox_for_teardown, fn _, _ ->
      {:error, :sandbox_unavailable}
    end)

    assert {:error, :sandbox_unavailable} = terminate(ctx)
    assert Repo.reload!(ctx.conv).status == "terminated"
    assert Repo.reload!(ctx.sandbox).status == "ready"
    assert events(ctx, "conversation.terminated") == []
  end

  # Before stage 5 the terminal write was the last step of this path, so a
  # refused write was the caller's error and this asserted `{:error,
  # :write_refused}` with the row left `ready`. The last step is now the
  # provider destroy's finalize, and a provider that cannot be reached must not
  # strand a fenced machine in a live status nobody will look at again — the
  # same rule the live-server path has always had ("a provider error still
  # retires the fenced row for reconciliation").
  test "a provider error still retires the fenced row and records the destroy", ctx do
    expect(Managoat.Sandbox, :destroy, fn _ -> {:error, :unavailable} end)

    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert Repo.reload!(ctx.sandbox).reset_requested_at
    assert [_] = events(ctx, "sandbox.teardown_requested")
    assert [_] = events(ctx, "sandbox.destroyed")
    assert [_] = events(ctx, "conversation.terminated")
  end

  test "a persistent machine remains available without a teardown intent", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.sandbox, mode: "persistent"))
    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.sandbox).status == "ready"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx, "sandbox.teardown_requested") == []
  end

  test "an already failed sandbox keeps its terminal state", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.sandbox, status: "failed"))
    assert :ok = terminate(ctx)
    assert Repo.reload!(ctx.conv).status == "terminated"
    assert Repo.reload!(ctx.sandbox).status == "failed"
    assert events(ctx, "sandbox.teardown_requested") == []
  end

  defp terminate(ctx),
    do: Termination.terminate_conversation(ctx.conv.id, actor: "ui", request_ip: "192.0.2.5")

  defp attach(ctx) do
    Launch.start_conversation(%{
      "user_id" => ctx.user.id,
      "agent_id" => ctx.agent.id,
      "sandbox_id" => ctx.sandbox.id
    })
  end

  defp events(ctx, action), do: Audit.list_for_user(ctx.user.id, action_prefix: action)
end
