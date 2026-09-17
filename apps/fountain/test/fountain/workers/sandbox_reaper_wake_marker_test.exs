defmodule Fountain.Workers.SandboxReaperWakeMarkerTest do
  @moduledoc """
  The reaper honours the wake-registration marker (ADR 0058 stage 6a, #2307
  constraint 4; lifted from the salvage branch `follow/2255-reaper-liveness-lock`
  and rewritten onto `woken_at`).

  Both of the reaper's liveness passes decide on `Lifecycle.any_server_alive?/1`,
  which reads Horde's registry — an asynchronous CRDT. A server started on
  another node moments ago is not there yet, and no amount of re-reading closes
  that, because "not here" is not "nowhere". `Conversations.register_server/2`
  commits `woken_at` before it asks Horde for a child, and these pass the
  registry the worst view it can have — no server at all — to show the marker
  alone keeping the row off both passes.

  The marker is a *grace*, not a veto: a caller that died between the two steps
  leaves one with no child, so both passes take the row again once it is past
  `@abandoned_grace_minutes`. That is the second case in each pair.
  """
  use Fountain.DataCase, async: false
  use Mimic

  import Ecto.Query

  alias Fountain.Conversations.Sandbox
  alias Fountain.Workers.SandboxReaper

  @grace_minutes 15

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    %{user: user, agent: agent}
  end

  # Straight onto the row, for two reasons: `changeset/2` deliberately does not
  # cast `woken_at`, and going through `Conversations.update_sandbox/2` would
  # move `updated_at` as well and confound the marker with the grace it sits
  # beside.
  defp mark_woken(sandbox, at) do
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [woken_at: at])
    sandbox
  end

  defp age(sandbox, minutes) do
    at = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [updated_at: at])
    Repo.reload!(sandbox)
  end

  describe "release_stuck_sandboxes/0" do
    setup ctx do
      sandbox =
        insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "starting")
        |> age(90)

      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: sandbox,
        status: "idle"
      )

      %{sandbox: sandbox}
    end

    test "without a marker, a row an hour past the cutoff is released", ctx do
      assert SandboxReaper.release_stuck_sandboxes() == 1
      assert Repo.reload!(ctx.sandbox).status == "failed"
    end

    test "a fresh marker keeps the row even when the registry says no server", ctx do
      mark_woken(ctx.sandbox, DateTime.utc_now())

      assert SandboxReaper.release_stuck_sandboxes() == 0
      assert Repo.reload!(ctx.sandbox).status == "starting"
    end

    test "a marker past the grace window is eligible again", ctx do
      mark_woken(
        ctx.sandbox,
        DateTime.add(DateTime.utc_now(), -(@grace_minutes + 15) * 60, :second)
      )

      assert SandboxReaper.release_stuck_sandboxes() == 1
      assert Repo.reload!(ctx.sandbox).status == "failed"
    end
  end

  describe "sweep_abandoned_sandboxes/0" do
    setup ctx do
      # The pass the registry lag actually bites: a wake that finds a `ready`
      # row and starts a server on it writes no status at all, so `updated_at`
      # says nothing happened and the marker is the only database fact there
      # is. Aged past both bounds, as the 83-day production row was, so the
      # verdict is the ceiling and the outcome is unambiguous.
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      insert_turn(conv, %{status: "completed"})
      %{sandbox: age_rows(sandbox, conv, 60 * 24 * 83)}
    end

    test "without a marker, a row past its ceiling is reclaimed", ctx do
      expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      with_bounds(fn ->
        assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end

    test "a fresh marker keeps the row and the machine, registry or no registry", ctx do
      reject(Managoat.Sandbox, :destroy, 1)
      reject(Managoat.Sandbox, :suspend, 1)
      mark_woken(ctx.sandbox, DateTime.utc_now())

      with_bounds(fn ->
        assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload!(ctx.sandbox).status == "ready"
    end

    test "a marker past the grace window is eligible again", ctx do
      expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      mark_woken(
        ctx.sandbox,
        DateTime.add(DateTime.utc_now(), -(@grace_minutes + 15) * 60, :second)
      )

      with_bounds(fn ->
        assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end
  end

  defp with_bounds(fun) do
    pairs = [sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24]
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp age_rows(sandbox, conv, minutes) do
    ts = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)

    Repo.update_all(
      from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: ts, updated_at: ts]
    )

    Repo.update_all(
      from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
      set: [inserted_at: ts]
    )

    Repo.reload!(sandbox)
  end
end
