defmodule Fountain.Machines.MidOperationReadersTest do
  @moduledoc """
  The readers that refuse a machine whose owner holds a live lease (ADR 0058
  stage 6a, #2307 constraint 2's reader half).

  Nothing writes `transition: "parking"` yet — stage 6b's park protocol does.
  6a puts the readers in front of it, so the writer lands behind readers that
  already honour it, and so the transitions that *do* exist today (`destroying`
  from the destroy protocol, and any live lease) stop being invisible to a wake
  or an attach.

  Three doors, one answer. `Wake.maybe_reuse_sandbox/1`,
  `Launch.check_attachable/4` (through the attach door, both of whose call
  sites share the function) and `Rehydrator`'s boot sweep each turn
  `Machine.busy?/2` into `:sandbox_unavailable` — the word the system already
  has, 503 with a `Retry-After`.

  **A live lease is the whole of the question** (round 1). A stamped
  `transition` whose lease has expired is an owner that *died* mid-operation,
  and every door here must read such a row exactly as `main` does — refusing it
  withheld a machine for as long as the sweep that gives up on the row takes to
  run. Each door has that case beside its refusal, asserting the `main` verdict
  rather than merely "not 503".

  Two orderings are load-bearing and each has a case here: the reset fence
  answers before the transition check, because a refused reset leaves
  `transition: "destroying"` on a live row with its lease released (stage 5c)
  and `:sandbox_reset_pending` is the precise thing to say about it; and a
  terminal row is never "busy", because a finalize writes the terminal status
  and releases the lease as two statements.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, Launch, Sandbox, Wake}
  alias Fountain.Machines.Machine

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: agent.environment_id,
        status: "ready",
        machine_name: "mid-op-#{System.unique_integer([:positive])}"
      )

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    %{user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  # The columns no changeset casts: an owner writes them through
  # `Machines.Lease`, and a test writes them the same way the database does.
  defp stamp(sandbox, changes) do
    sandbox |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  defp held(ttl_ms \\ 30_000) do
    [
      lease_epoch: 1,
      lease_node: "fountain@other",
      lease_until: DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
    ]
  end

  # The owner logs an info line when it clears an abandoned stamp; the suite runs
  # at `:warning`, so this is only about not leaking output.
  defp capture_answer(fun) do
    answer = :erlang.make_ref()
    Process.put(answer, nil)
    capture_log(fn -> Process.put(answer, fun.()) end)
    Process.get(answer)
  end

  defp conv_with_sandbox(ctx), do: Repo.reload!(ctx.conv) |> Repo.preload(:sandbox)

  describe "Machine.busy?/2" do
    # That the gate does not decide this is pinned in `machine_test.exs`,
    # which is `async: false` — writing `:machine_owner_enabled` from an async
    # module is what `async_global_config_guardrail_test.exs` refuses.
    test "a live lease, and nothing else", ctx do
      refute Machine.busy?(ctx.sandbox)

      assert Machine.busy?(stamp(ctx.sandbox, held()))
      refute Machine.busy?(stamp(ctx.sandbox, held(-1_000)))

      # A future `lease_until` with no holder is a row held by nobody, and
      # reads as such — the half the two SQL copies of this rule had dropped.
      # The deadline has to be in the future or this passes from the deadline
      # clause and never reaches the holder one (round 1, behaviour review).
      refute Machine.busy?(stamp(ctx.sandbox, Keyword.merge(held(), lease_node: nil)))
    end

    test "a stamped transition is not, on its own, an owner at work", ctx do
      # The round-1 correction. A transition with no live lease is an owner
      # that died mid-operation; `SandboxReaper.sweep_fenced_teardowns/0` calls
      # exactly that row abandoned, and two readers of one row must not
      # disagree. Refusing on it answered 503 until the sweep that gives up on
      # the row ran — hourly, so 16 to 75 minutes.
      released = stamp(ctx.sandbox, lease_epoch: 1, lease_node: nil, lease_until: nil)

      for transition <- Sandbox.transitions() do
        refute Machine.busy?(stamp(released, transition: transition)),
               "#{transition} with no live lease read as an owner at work"
      end

      # And with a live lease under it, every one of them is.
      for transition <- Sandbox.transitions() do
        assert Machine.busy?(stamp(released, Keyword.put(held(), :transition, transition)))
      end
    end
  end

  describe "Wake.maybe_reuse_sandbox/1" do
    test "a clean ready row probes and is reused", ctx do
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a parking row under a live lease is refused before the provider is asked", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, Keyword.put(held(), :transition, "parking"))

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a parking row whose lease died probes and reuses, exactly as on main", ctx do
      # The abandoned-operation case. `main` probes the provider here and hands
      # the caller the machine; so does 6a.
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      stamp(ctx.sandbox, transition: "parking", lease_epoch: 1, lease_node: nil, lease_until: nil)

      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an abandoned destroy answers its fence here, on this tree and on main", ctx do
      # The shape `Destroy` really leaves behind, which is not the one the
      # round-1 note reached for: it fences *before* it stamps, and the
      # teardown fence writes `reset_requested_at` beside
      # `teardown_requested_at`. So a destroy whose owner died carries both,
      # and this door answers the fence from its first clause — on `main` too.
      # The wake door was therefore never the live 6a regression; the
      # rehydrator's sweep was, because its query has no reset filter
      # (`rehydrator_test.exs` pins that). Recorded here so a later reader does
      # not go looking for a difference that is not at this door.
      reject(Managoat.Sandbox, :get, 1)

      stamp(ctx.sandbox,
        reset_requested_at: DateTime.utc_now(),
        teardown_requested_at: DateTime.utc_now(),
        transition: "destroying",
        lease_epoch: 1,
        lease_node: nil,
        lease_until: nil
      )

      assert {:error, :sandbox_reset_pending} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an abandoned park has no fence to answer, and reuses as on main", ctx do
      # And this is why the definition matters at 6b. A park carries no fence,
      # so a park whose owner died reaches `busy?/2` with nothing in front of
      # it: under the round-0 definition every wake onto it answered 503 until
      # a sweep gave up on the row, with no fence to make that the right
      # answer.
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)

      stamp(ctx.sandbox,
        transition: "parking",
        lease_epoch: 1,
        lease_node: nil,
        lease_until: nil
      )

      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "and the wake that follows that reuse is not refused either", ctx do
      # **The reader is only half the seam** (round 1 of #2368, behaviour
      # review). Stage 7a put `Machines.Resume` behind every reuse, and its
      # first draft read a lease-less stamp as a fence — so the reader above
      # handed the machine over and the owner refused it one call later, which
      # is 6a's decision undone one layer down. The two have to agree, so both
      # are asserted here rather than only the one this file was written for.
      stamp(ctx.sandbox,
        transition: "parking",
        lease_epoch: 1,
        lease_node: nil,
        lease_until: nil
      )

      assert {:ok, :already_up} =
               capture_answer(fn ->
                 Machine.ensure_up(ctx.sandbox.id, actor: "system:wake")
               end)

      assert is_nil(Repo.reload!(ctx.sandbox).transition),
             "the owner left the abandoned stamp on the row it just handed out"
    end

    test "a live lease is refused before the provider is asked", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, held())

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an expired lease is not a refusal", ctx do
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      stamp(ctx.sandbox, held(-1_000))

      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a suspended row under a live lease is refused too", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, Keyword.merge(held(), status: "suspended", transition: "resuming"))

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a provisioning row under a live lease still waits for the registry", ctx do
      # **Reversed in stage 7b, deliberately.** 6a pinned this as
      # `:sandbox_unavailable`, reasoning that a row an owner is holding has a
      # writer and the wake should come back. Nothing claimed a lease on a
      # `pending` row when that was written; the provision bracket does, for
      # its whole length, so the rule 6a stated for an *abandoned* operation
      # would have applied to every ordinary one — and `session/new` followed
      # by a prompt 30ms later is exactly that shape. Refusing it answers 503 to
      # the case #800 exists to serve, for minutes.
      #
      # So the door waits for the registry, as on `main`, and 6a's rule moved
      # to the decision it was really about: `wake_conversation_for/3`'s
      # `:timeout` arm asks whether an owner holds the machine before it
      # replaces one, which is the test below.
      stamp(ctx.sandbox, Keyword.merge(held(), status: "pending", transition: "provisioning"))

      assert {:provisioning, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a live lease refuses the replacement the registry's silence would make", ctx do
      # The other half. `await_registered/2` gives up after its settle window
      # and `main` then built a fresh machine; with a live lease on the row
      # that would be a second billable machine over one a server is still
      # building, wherever Horde's CRDT has got to.
      stamp(ctx.sandbox, Keyword.merge(held(), status: "pending", transition: "provisioning"))

      conv = conv_with_sandbox(ctx)

      assert {:error, :sandbox_unavailable} =
               capture_answer(fn -> Wake.wake_conversation(conv.id, "hello") end)

      assert Repo.reload!(ctx.sandbox).status == "pending",
             "the machine being provisioned was replaced anyway"
    end

    test "a provisioning row whose lease died still waits for the registry, as on main", ctx do
      stamp(ctx.sandbox,
        status: "pending",
        transition: "provisioning",
        lease_epoch: 1,
        lease_node: nil,
        lease_until: nil
      )

      assert {:provisioning, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "the reset fence wins over the transition it leaves behind", ctx do
      # Stage 5c's refused reset: a live `ready` row, its fence still stamped,
      # `transition: "destroying"` left on it, the lease released. The precise
      # answer is the fence (409, the reconciler will finish it), not "retry in
      # 30 seconds".
      reject(Managoat.Sandbox, :get, 1)

      stamp(ctx.sandbox,
        reset_requested_at: DateTime.utc_now(),
        transition: "destroying",
        lease_epoch: 1,
        lease_node: nil,
        lease_until: nil
      )

      assert {:error, :sandbox_reset_pending} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a terminal row is a fresh machine, however it is stamped", ctx do
      # A finalize writes `terminated` and releases the lease as two
      # statements, so terminal-and-held is a real momentary state. It means
      # the machine is gone, which is a new one — not a retry.
      stamp(ctx.sandbox, Keyword.merge(held(), status: "terminated", transition: "destroying"))

      assert :create_new = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a conversation with no machine is untouched", ctx do
      conv = conv_with_sandbox(ctx)
      assert :create_new = Wake.maybe_reuse_sandbox(%{conv | sandbox_id: nil})
    end
  end

  describe "Launch's attach door" do
    defp attach(ctx, sandbox) do
      Launch.start_conversation(%{
        "agent_id" => ctx.agent.id,
        "user_id" => ctx.user.id,
        "sandbox_id" => sandbox.id
      })
    end

    test "a clean row attaches", ctx do
      assert {:ok, _conv} = attach(ctx, ctx.sandbox)
    end

    test "a parking row under a live lease is refused", ctx do
      assert {:error, :sandbox_unavailable} =
               attach(ctx, stamp(ctx.sandbox, Keyword.put(held(), :transition, "parking")))
    end

    test "a parking row whose lease died attaches, exactly as on main", ctx do
      row =
        stamp(ctx.sandbox,
          transition: "parking",
          lease_epoch: 1,
          lease_node: nil,
          lease_until: nil
        )

      assert {:ok, _conv} = attach(ctx, row)
    end

    test "a permanent refusal outranks the transient one", ctx do
      # `Machine.busy?/2` is the *last* arm of the `cond`, after identity and
      # runtime (round 1, locks review). A mismatched attach onto a busy
      # machine must keep its permanent 422 rather than being told to retry at
      # something that will never work.
      other_agent = insert_agent(user_id: ctx.user.id)
      busy = stamp(ctx.sandbox, held())

      assert {:error, :sandbox_identity_mismatch} =
               Launch.start_conversation(%{
                 "agent_id" => other_agent.id,
                 "user_id" => ctx.user.id,
                 "sandbox_id" => busy.id
               })
    end

    test "a live lease is refused", ctx do
      assert {:error, :sandbox_unavailable} = attach(ctx, stamp(ctx.sandbox, held()))
    end

    test "the reset fence still wins, and says so precisely", ctx do
      row =
        stamp(ctx.sandbox,
          reset_requested_at: DateTime.utc_now(),
          transition: "destroying"
        )

      assert {:error, :sandbox_reset_pending} = attach(ctx, row)
    end

    test "a terminal row keeps its own answer", ctx do
      row = stamp(ctx.sandbox, Keyword.merge(held(), status: "terminated"))
      assert {:error, {:sandbox_not_attachable, "terminated"}} = attach(ctx, row)
    end

    test "only the locked re-read can refuse when the lease arrives after the preflight", ctx do
      # The locked `FOR NO KEY UPDATE` re-read's own coverage (round 1,
      # behaviour review). The previous version of this case carried a prompt,
      # which put `ConversationServer.send_prompt/4` — and so `Wake` — in the
      # path *after* the attach committed, so the `:sandbox_unavailable` it
      # asserted could come from either reader and deleting both guards left it
      # green.
      #
      # No prompt here, so `Wake` is never reached, and the hook is
      # `InferenceCredentials.lock_source/1`, which `create_attached_conversation/3`
      # calls as the first statement inside its transaction — after the
      # preflight `check_attachable/4` has already passed and before the
      # `FOR NO KEY UPDATE` re-read. Only the locked check can produce this
      # answer.
      test_pid = self()

      stub(Fountain.InferenceCredentials, :lock_source, fn _user_id ->
        send(test_pid, {:preflight_saw, Repo.reload!(ctx.sandbox).lease_node})
        stamp(ctx.sandbox, held())
        :ok
      end)

      assert {:error, :sandbox_unavailable} =
               Launch.start_conversation(%{
                 "agent_id" => ctx.agent.id,
                 "user_id" => ctx.user.id,
                 "sandbox_id" => ctx.sandbox.id
               })

      # The row was unheld when the preflight ran, so the preflight cannot be
      # what refused.
      assert_received {:preflight_saw, nil}

      # And the locked arm rolled its transaction back: nothing was created.
      assert Repo.aggregate(from(c in Conversation), :count) == 1
    end
  end
end
