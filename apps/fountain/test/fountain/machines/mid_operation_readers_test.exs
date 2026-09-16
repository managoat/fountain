defmodule Fountain.Machines.MidOperationReadersTest do
  @moduledoc """
  The readers that refuse a machine its owner is mid-operation on (ADR 0058
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

  Two orderings are load-bearing and each has a case here: the reset fence
  answers before the transition check, because a refused reset leaves
  `transition: "destroying"` on a live row with its lease released (stage 5c)
  and `:sandbox_reset_pending` is the precise thing to say about it; and a
  terminal row is never "busy", because a finalize writes the terminal status
  and releases the lease as two statements.
  """
  use Fountain.DataCase, async: true
  use Mimic

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

  defp conv_with_sandbox(ctx), do: Repo.reload!(ctx.conv) |> Repo.preload(:sandbox)

  describe "Machine.busy?/2" do
    # That the gate does not decide this is pinned in `machine_test.exs`,
    # which is `async: false` — writing `:machine_owner_enabled` from an async
    # module is what `async_global_config_guardrail_test.exs` refuses.
    test "a stamped transition or a live lease, and nothing else", ctx do
      refute Machine.busy?(ctx.sandbox)

      for transition <- Sandbox.transitions() do
        assert Machine.busy?(stamp(ctx.sandbox, transition: transition)),
               "#{transition} did not read as mid-operation"
      end

      clean = stamp(ctx.sandbox, transition: nil)
      refute Machine.busy?(clean)

      assert Machine.busy?(stamp(clean, held()))
      refute Machine.busy?(stamp(clean, held(-1_000)))

      # A `lease_until` with no holder is a row held by nobody, and reads as
      # such — the half the two SQL copies of this rule had dropped.
      refute Machine.busy?(stamp(clean, lease_node: nil))
    end
  end

  describe "Wake.maybe_reuse_sandbox/1" do
    test "a clean ready row probes and is reused", ctx do
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      assert {:reuse, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a parking row is refused before the provider is asked", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, transition: "parking")

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a live lease is refused before the provider is asked", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, held())

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an expired lease is not a refusal", ctx do
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      stamp(ctx.sandbox, held(-1_000))

      assert {:reuse, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a suspended row mid-operation is refused too", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, status: "suspended", transition: "resuming")

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a provisioning row mid-operation is refused rather than waited for", ctx do
      # `{:provisioning, id}` sends the caller to `await_registered/2` and then
      # to a fresh machine. A row an owner is holding is not that: it has a
      # writer, and the wake should come back.
      stamp(ctx.sandbox, status: "pending", transition: "provisioning")

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
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

    test "a parking row is refused", ctx do
      assert {:error, :sandbox_unavailable} =
               attach(ctx, stamp(ctx.sandbox, transition: "parking"))
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

    test "the verdict that counts is the one under the admission lock", ctx do
      # `check_attachable/4` runs twice: once on the preflight read, and again
      # inside `create_attached_conversation/3`'s `FOR NO KEY UPDATE` re-read.
      # The second is the one that decides, because a pre-lock verdict is stale
      # by construction (#2307 constraint 1) — an owner can take the machine
      # between them.
      #
      # `RuntimeDispatch.concurrency/1` runs between the two (the capacity
      # check a prompt-carrying attach makes), so stamping the row from there
      # reproduces that window deterministically, without depending on two
      # processes' timing.
      stub(Fountain.RuntimeDispatch, :concurrency, fn _runtime ->
        stamp(ctx.sandbox, transition: "parking")
        99
      end)

      assert {:error, :sandbox_unavailable} =
               Launch.start_conversation(%{
                 "agent_id" => ctx.agent.id,
                 "user_id" => ctx.user.id,
                 "sandbox_id" => ctx.sandbox.id,
                 "prompt" => "hello"
               })

      # And nothing was created: the locked arm rolls its transaction back.
      assert Repo.aggregate(from(c in Conversation), :count) == 1
    end
  end
end
