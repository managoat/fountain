defmodule Fountain.SandboxFenceColumnsDropMigrationTest do
  @moduledoc """
  The drop of the two fence columns (ADR 0058, stage 9b-ii) re-runs v0.20.1's
  backfill first, so a column-only fence a v0.19.0 replica wrote after the
  backfill ran, during a rolling upgrade, is stamped before the columns go. It
  also deletes the queued jobs of the reconciler worker this release removes.

  Each test starts where a database stands after `20260918190000`: `setup`
  puts the two columns back (the suite's database has already dropped them),
  and the rows are then written in v0.19.0's shape with raw SQL, as a v0.19.0
  replica would write them after the backfill. The real migration then runs,
  inside the test's transaction, which rolls the drop back afterwards.

  `async: false`: the reaper's run is global (Mimic stubs, app env for
  provider credentials), and the DDL holds a table lock until the test's
  transaction rolls back. The row helpers follow
  `sandbox_fence_backfill_migration_test.exs`.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Repo.Migrations.DropSandboxFenceColumns, as: Migration
  alias Fountain.Workers.SandboxReaper

  @version 20_260_918_200_000
  @reconciler "Fountain.Workers.SandboxResetReconciler"

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20260918200000_drop_sandbox_fence_columns.exs",
      __DIR__
    )
  end

  setup :set_mimic_global

  setup do
    Repo.query!("""
    ALTER TABLE sandboxes
      ADD COLUMN IF NOT EXISTS reset_requested_at timestamp(6) without time zone,
      ADD COLUMN IF NOT EXISTS teardown_requested_at timestamp(6) without time zone
    """)

    :ok
  end

  describe "a fence a v0.19.0 replica wrote after the backfill ran" do
    test "is stamped with its own reason before the columns go" do
      user = insert_verified_user()

      # What the backfill already did, before these were written.
      earlier = v019_row(user, "ready", "persistent", reset: 90)
      set_raw(earlier, "transition = 'destroying', transition_reason = 'reset'")

      # Written by a v0.19.0 replica still serving after the backfill.
      reset = v019_row(user, "ready", "persistent", reset: 3)
      teardown = v019_row(user, "ready", "ephemeral", reset: 3, teardown: 3)
      # A home reset, then escalated to a teardown: both columns, and a shape
      # the reset door would take. The teardown must win.
      escalated = v019_row(user, "suspended", "persistent", reset: 9, teardown: 3)
      finished = v019_row(user, "terminated", "persistent", reset: 3)
      unfenced = v019_row(user, "ready", "persistent", [])

      log = run_migration()

      assert transition(reset) == {"destroying", "reset"}
      assert transition(teardown) == {"destroying", "teardown"}
      assert transition(escalated) == {"destroying", "teardown"}
      assert transition(earlier) == {"destroying", "reset"}
      assert transition(finished) == {nil, nil}
      assert transition(unfenced) == {nil, nil}

      assert log =~ "stamped 3 sandbox(es)"
      assert fence_columns() == []
    end

    test "is then finished by the teardown run" do
      with_sprites_credentials(fn ->
        user = insert_verified_user()
        reset = v019_row(user, "ready", "persistent", reset: 60)
        teardown = v019_row(user, "ready", "ephemeral", reset: 60, teardown: 60)
        destroys = capture_destroys()

        run_migration()

        capture_log(fn ->
          assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
        end)

        assert Repo.get!(Sandbox, reset).status == "terminated"
        assert Repo.get!(Sandbox, teardown).status == "terminated"
        assert Enum.sort(destroys.()) == Enum.sort([name(reset), name(teardown)])

        # Each through its own door: the reset records a reset, the teardown a
        # destroy with the reason the fence meant.
        assert [completed] = audits(user, "sandbox.reset", reset)
        assert completed.metadata["reason"] == "reset_reconciled"
        assert [] = audits(user, "sandbox.destroyed", reset)

        assert [destroyed] = audits(user, "sandbox.destroyed", teardown)
        assert destroyed.metadata["reason"] == "teardown"
      end)
    end

    test "a reset on a machine used since is skipped and logged, and the drop discards it" do
      user = insert_verified_user()

      used = v019_row(user, "ready", "persistent", reset: 3)
      turn_at(used, 1)

      # One the backfill skipped already: logged again, where it is discarded.
      skipped_before = v019_row(user, "suspended", "persistent", reset: 90)
      turn_at(skipped_before, 30)

      # A teardown is finished however recently the machine was used.
      teardown = v019_row(user, "ready", "ephemeral", reset: 3, teardown: 3)
      turn_at(teardown, 1)

      log = run_migration()

      assert transition(used) == {nil, nil}
      assert transition(skipped_before) == {nil, nil}
      assert transition(teardown) == {"destroying", "teardown"}

      assert log =~ "left sandbox #{used}"
      assert log =~ "left sandbox #{skipped_before}"
      refute log =~ "left sandbox #{teardown}"
      assert log =~ "stamped 1 sandbox(es)"

      assert fence_columns() == []
      assert %Sandbox{status: "ready", transition: nil} = Repo.get!(Sandbox, used)
    end
  end

  describe "the removed reconciler's queued jobs" do
    test "are deleted; its finished jobs and every other worker's are kept" do
      queued =
        for state <- ["available", "scheduled", "retryable"],
            do: job(@reconciler, state, %{"sandbox_id" => Ecto.UUID.generate()})

      cron = job(@reconciler, "available", %{})
      completed = job(@reconciler, "completed", %{})
      discarded = job(@reconciler, "discarded", %{})
      other = job("Fountain.Workers.SandboxReaper", "available", %{"pass" => "teardowns"})

      log = run_migration()

      for id <- [cron | queued], do: refute(job_exists?(id))
      for id <- [completed, discarded, other], do: assert(job_exists?(id))
      assert log =~ "deleted 4 queued #{@reconciler} job(s)"
    end
  end

  # A row as v0.19.0 left it: `updated_at` is the fence's own write, and
  # `transition`, `transition_reason` and the lease are what the lease
  # migration adds to a row it did not write.
  defp v019_row(user, status, mode, fences) do
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: status, mode: mode)
    reset = Keyword.get(fences, :reset)
    teardown = Keyword.get(fences, :teardown)
    last_write = Enum.min(Enum.reject([reset, teardown, 120], &is_nil/1))

    Repo.query!(
      """
      UPDATE sandboxes
         SET reset_requested_at = timezone('UTC', now()) - make_interval(mins => $2::int),
             teardown_requested_at = timezone('UTC', now()) - make_interval(mins => $3::int),
             updated_at = date_trunc('second', timezone('UTC', now()) - make_interval(mins => $4::int)),
             transition = NULL, transition_reason = NULL,
             lease_node = NULL, lease_until = NULL, lease_epoch = 0
       WHERE id = $1
      """,
      [dump(sandbox.id), reset, teardown, last_write]
    )

    sandbox.id
  end

  defp turn_at(sandbox_id, minutes) do
    sandbox = Repo.get!(Sandbox, sandbox_id)
    conv = insert_conversation(user_id: sandbox.user_id, sandbox: sandbox, status: "idle")
    turn = insert_turn(conv, %{})

    Repo.query!(
      """
      UPDATE turns
         SET inserted_at = date_trunc('second', timezone('UTC', now()) - make_interval(mins => $2::int))
       WHERE id = $1
      """,
      [dump(turn.id), minutes]
    )

    turn
  end

  defp job(worker, state, args) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO oban_jobs (worker, queue, args, state, max_attempts)
        VALUES ($1, 'maintenance', $2, $3::oban_job_state, 10)
        RETURNING id
        """,
        [worker, args, state]
      )

    id
  end

  defp job_exists?(id) do
    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM oban_jobs WHERE id = $1)", [id])

    exists
  end

  defp fence_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
       WHERE table_schema = current_schema() AND table_name = 'sandboxes'
         AND column_name IN ('reset_requested_at', 'teardown_requested_at')
      """)

    rows
  end

  defp set_raw(id, assignments) do
    Repo.query!("UPDATE sandboxes SET #{assignments} WHERE id = $1", [dump(id)])
  end

  defp transition(id) do
    %{rows: [row]} =
      Repo.query!("SELECT transition, transition_reason FROM sandboxes WHERE id = $1", [dump(id)])

    List.to_tuple(row)
  end

  defp name(id), do: Repo.get!(Sandbox, id).machine_name

  defp audits(user, action, id) do
    user.id
    |> Fountain.Audit.list_for_user(action_prefix: action)
    |> Enum.filter(&(&1.action == action and &1.resource_id == id))
  end

  defp capture_destroys do
    {:ok, destroyed} = Agent.start_link(fn -> [] end)

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      Agent.update(destroyed, &[handle.name | &1])
      :ok
    end)

    fn -> Agent.get_and_update(destroyed, &{Enum.reverse(&1), []}) end
  end

  defp with_sprites_credentials(fun) do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, token: "test")

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous),
        else: Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    end
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp run_migration do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        @version,
        Migration,
        :forward,
        :up,
        :up,
        log: false
      )
    end)
  end
end
