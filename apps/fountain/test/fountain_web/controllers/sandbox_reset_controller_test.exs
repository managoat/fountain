defmodule FountainWeb.SandboxResetControllerTest do
  # DELETE /api/sandboxes/:id (#1071), at the door.
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Repo

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        environment_id: env.id,
        provider: "sprites"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, user: user, raw_key: raw_key, agent: agent, home: home, conv: conv}
  end

  defp reset(ctx, id) do
    ctx.conn |> authed_with_key(ctx.raw_key) |> delete("/api/sandboxes/#{id}")
  end

  test "204: the home is terminated and the conversation kept", ctx do
    assert ctx |> reset(ctx.home.id) |> response(204)
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
    assert Conversations._unsafe_get_conversation!(ctx.conv.id).status == "idle"
  end

  test "404 for another tenant's sandbox, and for a made-up id", ctx do
    other = insert_active_user()
    theirs = insert_sandbox(user_id: other.id, status: "ready", mode: "persistent")

    assert %{"error" => "not_found"} = ctx |> reset(theirs.id) |> json_response(404)
    assert Conversations._unsafe_get_sandbox!(theirs.id).status == "ready"
    assert ctx |> reset(Ecto.UUID.generate()) |> json_response(404)
    assert ctx |> reset("nope") |> json_response(404)
  end

  test "422 sandbox_not_resettable for an ephemeral sandbox", ctx do
    ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")

    assert %{"error" => "sandbox_not_resettable", "reason" => "ephemeral"} =
             ctx |> reset(ephemeral.id) |> json_response(422)
  end

  test "422 sandbox_not_resettable for a home already gone", ctx do
    assert ctx |> reset(ctx.home.id) |> response(204)

    assert %{"error" => "sandbox_not_resettable", "reason" => "terminated"} =
             ctx |> reset(ctx.home.id) |> json_response(422)
  end

  test "409 sandbox_mid_turn while a conversation on it runs a turn", ctx do
    insert_turn(ctx.conv, status: "running")
    assert %{"error" => "sandbox_mid_turn"} = ctx |> reset(ctx.home.id) |> json_response(409)
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
  end

  test "409 execution_fenced while a bounded turn owes a remote stop", ctx do
    # ADR 0046: the turn has ended locally, so `:sandbox_mid_turn` does not
    # apply, but a session was named and its termination was never confirmed,
    # so the journal still owes a remote stop. Before this had a
    # FallbackController clause the atom fell through to the unmapped-atom net
    # and the caller got a 422 carrying no message.
    alias Fountain.Conversations.ExecutionGuard

    turn = insert_turn(ctx.conv, status: "running")
    connection_id = Ecto.UUID.generate()

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        connection_id,
        DateTime.add(DateTime.utc_now(), 60, :second)
      )

    # Without these two the journal stops on its own at the failed write —
    # nothing was ever spawned, so nothing is owed and the reset succeeds.
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)
    {:ok, _} = ExecutionGuard._unsafe_bind_identity(execution.id, connection_id, "sess-1")
    {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "failed"})

    assert Repo.get!(Fountain.Conversations.TurnExecution, execution.id).state == "ready"

    assert %{"error" => "execution_fenced", "message" => message} =
             ctx |> reset(ctx.home.id) |> json_response(409)

    assert message =~ "never confirmed"
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
  end

  test "503 when another teardown of the same machine is running", ctx do
    # ADR 0058 stage 5c: the reset destroys through the machine's owner, which
    # refuses while somebody else holds the machine's lease. Reachable through
    # the window between a forced destroy's lease claim and its fence — until
    # that fence commits, the row still looks resettable to this endpoint, and
    # the claim is where the two meet. The operation declares
    # `service_unavailable` for it, so the schema guard and the four SDKs know
    # the shape.
    stub(Fountain.Machines.Destroy, :run, fn _id, _opts -> {:error, :machine_busy} end)

    conn =
      ExUnit.CaptureLog.with_log(fn -> reset(ctx, ctx.home.id) end) |> elem(0)

    # With a message, unlike the shared `FallbackController` clause, and the
    # message is the one thing a caller must not get wrong here: the fence
    # committed before the refusal, so "send it again" is exactly the wrong
    # advice — the next call answers 409 from the fence this one wrote.
    assert %{"error" => "sandbox_unavailable", "message" => message} =
             json_response(conn, 503)

    assert message =~ "sandbox_reset_pending"
    assert get_resp_header(conn, "retry-after") == ["30"]

    # The fence committed before the machine was ever claimed, and a refusal
    # does not take it back: the machine is closed to admission and
    # `SandboxResetReconciler` owns it from here. That is the same durable
    # state an unconfirmed delete leaves, and the reason this is a retryable
    # refusal rather than a failure.
    current = Conversations._unsafe_get_sandbox!(ctx.home.id)
    assert current.status == "ready"
    assert current.reset_requested_at

    # And the reason the message says what it says: the fence this call wrote
    # is what refuses the next one, busy owner or not. `docs/concepts/sandboxes.md`
    # makes this promise to readers.
    assert %{"error" => "sandbox_reset_pending"} =
             ctx |> reset(ctx.home.id) |> json_response(409)

    assert Fountain.Audit.list_for_user(ctx.user.id)
           |> Enum.map(& &1.action)
           |> Enum.member?("sandbox.reset") == false
  end

  test "the reset is audited as api", ctx do
    assert ctx |> reset(ctx.home.id) |> response(204)

    assert [event] =
             Fountain.Audit.list_for_user(ctx.user.id)
             |> Enum.filter(&(&1.action == "sandbox.reset"))

    assert event.actor == "api"
  end
end
