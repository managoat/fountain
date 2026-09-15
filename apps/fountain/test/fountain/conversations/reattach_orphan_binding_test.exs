defmodule Fountain.Conversations.ReattachOrphanBindingTest do
  @moduledoc """
  The reattach path's orphan write is bound to the actor's own sandbox (#2021).

  `Reattachment.mark_orphan/3` is the reattach path's give-up: every way of
  failing to find or attach to the sprite's session ends there, and it flips
  the conversation's running turn to `interrupted`. Its turn comes from
  `find_running_turn/1`, which is scoped by conversation and not by sandbox —
  so a stale actor reaching it would reconcile a *successor's* live turn on a
  replacement machine. These tests pin both directions: the bound actor still
  reconciles, and the rebound one writes nothing.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Reattachment

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    %{user: user, sandbox: sandbox, conv: conv, turn: turn}
  end

  # `{:denied, _}` is classified permanent by `Managoat.Sandbox.Retry`, so the
  # listing fails on its first attempt and the test does not pay for backoff.
  defp fail_listing do
    stub(Managoat.Sandbox, :list_sessions, fn _handle -> {:error, {:denied, :stale_actor}} end)
  end

  defp state(conv_id, sandbox_id),
    do: %{conversation_id: conv_id, sandbox_id: sandbox_id, handle: :handle}

  test "an actor still holding the binding reconciles its own turn", ctx do
    fail_listing()

    capture_log(fn ->
      assert Reattachment.reattach_running_turn(state(ctx.conv.id, ctx.sandbox.id))
    end)

    assert Repo.reload!(ctx.turn).status == "interrupted"
    assert Repo.reload!(ctx.turn).orphaned_at
    assert Repo.reload!(ctx.conv).status == "idle"
  end

  test "an actor whose conversation was rebound leaves the successor's turn alone", ctx do
    # Actor A restarted on the sandbox it was launched with. While it was away
    # the conversation was rebound to a replacement and actor B admitted a turn
    # on it. A's listing then fails under a partition: without the fence this
    # interrupts B's live turn and idles a conversation that is still working.
    replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
    {:ok, _} = Fountain.Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})
    fail_listing()

    log =
      capture_log(fn ->
        assert Reattachment.reattach_running_turn(state(ctx.conv.id, ctx.sandbox.id))
      end)

    assert Repo.reload!(ctx.turn).status == "running"
    refute Repo.reload!(ctx.turn).orphaned_at
    assert Repo.reload!(ctx.conv).status == "running"
    assert log =~ "not orphaning turn"
  end
end
