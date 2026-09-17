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
  #
  # **The stub records; the test asserts.** Every one of the assertions below
  # used to sit inside this stub body, where `Destroy.destroy_at_provider/2`
  # rescues a raise out of the adapter and hands it back as `{:error,
  # formatted}` — so all six failed nothing, and an unconditional `flunk` in
  # the body still gave six tests and no failures (round 1, behaviour review).
  # Mimic cannot catch it either: its `reject`/`expect` violations are reported
  # by the raise at the call site and by nothing else, so the same rescue eats
  # those too. Anything only the provider call can see is sent to the test
  # process and judged after `terminate/1` returns.
  test "fences attachments, destroys the machine and attributes both events", ctx do
    machine_name = ctx.sandbox.machine_name
    test_pid = self()

    expect(Managoat.Sandbox, :destroy, fn %Managoat.Sandbox.Handle{name: ^machine_name} ->
      send(
        test_pid,
        {:at_provider,
         %{
           in_transaction?: Repo.in_transaction?(),
           fenced: Repo.reload!(ctx.sandbox),
           racing_attach: attach(ctx)
         }}
      )

      :ok
    end)

    assert :ok = terminate(ctx)

    assert_received {:at_provider, observed}
    refute observed.in_transaction?
    assert observed.fenced.reset_requested_at
    assert observed.fenced.teardown_requested_at
    # Durable intent, stamped before the provider call and before the row is
    # terminal: a reader sees what is being done to the machine (ADR 0058).
    assert observed.fenced.transition == "destroying"
    assert observed.fenced.status == "ready"
    assert {:error, :sandbox_reset_pending} = observed.racing_attach

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

  # Rewritten at ADR 0058 stage 6a, and again at 8b. Stage 6a asserted that an
  # attach landing between the destroy's lease claim and its fence was refused
  # on the lease (`:sandbox_unavailable`). Stage 8b put the last-detach
  # decision in front of the destroy: `Machine.detach/2` fences under the
  # machine's lock first, and only then does `Machine.destroy/2` claim its
  # lease and repeat the fence. So the point at which this machine stops taking
  # new work is the detach's commit, and an attach that arrives after it meets
  # the fence — `:sandbox_reset_pending`, the 409 that says the machine is
  # going, which is what an attach after `main`'s fence always met. The lease
  # window 6a closed is still closed for the forced destroys, which fence
  # under their lease (`destroy_forced_test.exs`); on this path there is no
  # longer a moment between "decided" and "closed" for an attach to land in.
  #
  # Both fence calls are expected: the detach's, which carries the terminating
  # conversation and makes the decision, and the destroy's repeat, which does
  # not. The attach is tried after the first has committed.
  # Recording rather than asserting in the stub, for the reason the test above
  # gives: this one's raise would land inside the fence's own transaction
  # rather than under the destroy's rescue, but the shape is the trap and the
  # rule is the same everywhere in this file.
  test "an attachment that arrives after the detach has decided is refused", ctx do
    test_pid = self()

    expect(Lifecycle, :fence_sandbox_for_teardown, 2, fn sandbox, opts ->
      result = Mimic.call_original(Lifecycle, :fence_sandbox_for_teardown, [sandbox, opts])

      if Keyword.has_key?(opts, :terminating_conversation_id) do
        send(test_pid, {:after_the_detachs_fence, result, attach(ctx)})
      end

      result
    end)

    expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

    assert :ok = terminate(ctx)

    assert_received {:after_the_detachs_fence, fence_result, racing_attach}
    assert {:ok, _fenced} = fence_result
    assert {:error, :sandbox_reset_pending} = racing_attach

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
