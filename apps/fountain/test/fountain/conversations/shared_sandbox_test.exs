defmodule Fountain.Conversations.SharedSandboxTest do
  # The context-level rules for a sandbox that several conversations hold
  # (ADR 0023 steps 4 and 5): capacity at turn start, co-tenancy, and the
  # machine-wide idle verdict.
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Machines.Machine
  alias Fountain.Repo

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "opencode")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, agent: agent, sandbox: sandbox, a: a, b: b}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp running_turn(conv) do
    insert_turn(conv, %{status: "running", prompt: "go", started_at: now()})
  end

  # A turn that ended `ago` seconds in the past, with its row dated to match.
  defp old_turn(conv, ago) do
    at = DateTime.add(now(), -ago, :second)

    conv
    |> insert_turn(%{status: "completed", prompt: "done", started_at: at, ended_at: at})
    |> Ecto.Changeset.change(inserted_at: at)
    |> Repo.update!()
  end

  describe "_unsafe_running_turns_elsewhere/2" do
    test "counts other conversations' running turns only", %{a: a, b: b, sandbox: sandbox} do
      assert Conversations._unsafe_running_turns_elsewhere(sandbox.id, a.id) == 0

      running_turn(b)
      old_turn(b, 10)
      running_turn(a)

      assert Conversations._unsafe_running_turns_elsewhere(sandbox.id, a.id) == 1
      assert Conversations._unsafe_running_turns_elsewhere(sandbox.id, b.id) == 1
    end
  end

  # A third conversation on the same machine, on a runtime with no bound. The
  # per-runtime count (ADR 0058 stage 8a) is what keeps it and the two opencode
  # conversations from consuming each other's slots.
  defp claude_cotenant(%{user: user, sandbox: sandbox}) do
    agent = insert_agent(user_id: user.id, runtime: "claude")
    insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
  end

  defp attrs(conv) do
    %{
      conversation_id: conv.id,
      turn_number: 1,
      prompt: "hi",
      status: "running",
      started_at: now()
    }
  end

  describe "_unsafe_create_turn_on_sandbox/3" do
    # The owner's write, driven directly here: `Machine.admit_turn/3` is the door
    # and `admission_test.exs` pins that it is the only caller in `lib/`. The
    # bound is the conversation's runtime, read under the lock — there is no
    # capacity argument since stage 8a.
    test "refuses at capacity and writes nothing", %{a: a, b: b, sandbox: sandbox} do
      running_turn(b)

      assert {:error, :sandbox_at_capacity} =
               Conversations._unsafe_create_turn_on_sandbox(attrs(a), sandbox.id)

      assert Conversations._unsafe_list_turns(a.id) == []
    end

    for status <- ["terminated", "failed"] do
      test "admission refuses a persisted #{status} sandbox", ctx do
        ctx.sandbox |> Ecto.Changeset.change(status: unquote(status)) |> Repo.update!()

        assert {:error, :sandbox_unavailable} =
                 Conversations._unsafe_create_turn_on_sandbox(attrs(ctx.a), ctx.sandbox.id)

        assert Conversations._unsafe_list_turns(ctx.a.id) == []
      end
    end

    test "admission refuses the previous sandbox after a move", ctx do
      fresh = insert_sandbox(user_id: ctx.user.id, status: "ready")
      ctx.a |> Ecto.Changeset.change(sandbox_id: fresh.id) |> Repo.update!()

      assert {:error, :sandbox_unavailable} =
               Conversations._unsafe_create_turn_on_sandbox(attrs(ctx.a), ctx.sandbox.id)

      assert Conversations._unsafe_list_turns(ctx.a.id) == []
    end

    test "autonomous admission honors the runtime capacity too", ctx do
      running_turn(ctx.b)

      assert {:error, :sandbox_at_capacity} =
               Fountain.Conversations.Connection.open_autonomous_turn(
                 ctx.a.id,
                 ctx.user.id,
                 ctx.sandbox.id,
                 ctx.a.configuration_revision,
                 ctx.a.inference_source
               )

      assert Conversations._unsafe_list_turns(ctx.a.id) == []
      assert Conversations._unsafe_get_conversation!(ctx.a.id).status == "idle"
    end

    test "inserts below capacity", %{a: a, sandbox: sandbox} do
      assert {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs(a), sandbox.id)
      assert turn.status == "running"
    end

    test "an unbounded runtime never refuses", ctx do
      # Two claude conversations mid-turn on the machine, and a third admitted:
      # claude has no bound, so nothing on the machine counts against it.
      running_turn(claude_cotenant(ctx))
      running_turn(claude_cotenant(ctx))

      assert {:ok, _} =
               Conversations._unsafe_create_turn_on_sandbox(
                 attrs(claude_cotenant(ctx)),
                 ctx.sandbox.id
               )
    end
  end

  describe "capacity is counted per runtime (ADR 0058 stage 8a, #1089 blocker 4)" do
    # On `main` every running turn on the machine counted against the asker's
    # bound whatever runtime it ran on, so a claude turn consumed the one
    # opencode slot on a shared home. Both directions are pinned, and the
    # same-runtime refusal beside them so the fix cannot be "count nothing".
    test "a claude turn does not consume the opencode slot", ctx do
      running_turn(claude_cotenant(ctx))

      assert {:ok, _} = Conversations._unsafe_create_turn_on_sandbox(attrs(ctx.a), ctx.sandbox.id)
    end

    test "an opencode turn does not refuse a claude turn", ctx do
      running_turn(ctx.b)

      assert {:ok, _} =
               Conversations._unsafe_create_turn_on_sandbox(
                 attrs(claude_cotenant(ctx)),
                 ctx.sandbox.id
               )
    end

    test "an opencode turn still refuses the other opencode conversation", ctx do
      running_turn(claude_cotenant(ctx))
      running_turn(ctx.b)

      assert {:error, :sandbox_at_capacity} =
               Conversations._unsafe_create_turn_on_sandbox(attrs(ctx.a), ctx.sandbox.id)
    end

    test "the unlocked read asks the same question", ctx do
      claude = claude_cotenant(ctx)
      running_turn(claude)

      refute Machine.at_capacity?(ctx.sandbox.id, ctx.a.id, "opencode")
      refute Machine.at_capacity?(ctx.sandbox.id, nil, "claude")

      running_turn(ctx.b)
      assert Machine.at_capacity?(ctx.sandbox.id, ctx.a.id, "opencode")
      assert Machine.at_capacity?(ctx.sandbox.id, nil, "opencode")
      refute Machine.at_capacity?(ctx.sandbox.id, ctx.b.id, "opencode")
      refute Machine.at_capacity?(ctx.sandbox.id, claude.id, "claude")
    end

    test "the count itself takes the runtime", ctx do
      running_turn(claude_cotenant(ctx))
      running_turn(ctx.b)

      assert Conversations._unsafe_running_turns_elsewhere(ctx.sandbox.id, ctx.a.id) == 2

      assert Conversations._unsafe_running_turns_elsewhere(ctx.sandbox.id, ctx.a.id, "opencode") ==
               1

      assert Conversations._unsafe_running_turns_elsewhere(ctx.sandbox.id, ctx.a.id, "claude") ==
               1

      assert Conversations._unsafe_running_turns_elsewhere(ctx.sandbox.id, nil, "gemini") == 0
    end
  end

  describe "_unsafe_list_cotenant_ids/2" do
    test "lists the live conversations on the machine other than this one", ctx do
      assert Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, ctx.a.id) == [ctx.b.id]

      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})
      assert Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, ctx.a.id) == []
    end
  end

  describe "_unsafe_sandbox_busy_elsewhere?/4" do
    test "no co-tenant, or the bound switched off, is never busy", ctx do
      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, nil)
    end

    test "a co-tenant mid-turn is busy however old the turn is", ctx do
      turn = running_turn(ctx.b)
      old = DateTime.add(now(), -99_999, :second)
      turn |> Ecto.Changeset.change(inserted_at: old, started_at: old) |> Repo.update!()

      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end

    test "a co-tenant that finished a turn recently is busy; long ago is not", ctx do
      old_turn(ctx.b, 7200)
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)

      old_turn(ctx.b, 60)
      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end

    test "a co-tenant that never took a turn counts by its own row's age", ctx do
      # Fresh row: touched just now.
      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)

      old = DateTime.add(now(), -7200, :second)
      ctx.b |> Ecto.Changeset.change(updated_at: old) |> Repo.update!()
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end

    test "this conversation's own activity does not count", ctx do
      running_turn(ctx.a)
      old = DateTime.add(now(), -7200, :second)
      ctx.b |> Ecto.Changeset.change(updated_at: old) |> Repo.update!()
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end
  end
end
