defmodule Fountain.SandboxFenceBackfillMigrationTest do
  @moduledoc """
  The v0.20.1 backfill: a fence v0.19.0 wrote only in the two columns becomes
  the `destroying` stamp v0.20.x reads, and the reaper's teardown run then
  finishes it.

  Rows are seeded in v0.19.0's shape with raw SQL, because the `Sandbox` schema
  no longer declares the columns: `transition`, `transition_reason` and the
  lease are null, which is what the lease migration leaves on a row it did not
  write, and the fence is only in `reset_requested_at` and
  `teardown_requested_at`.

  `async: false` for two reasons. The reaper's run is global (Mimic stubs,
  app env for provider credentials). And `setup` re-adds the two columns with
  `IF NOT EXISTS`, so this file survives the migration that drops them; that
  DDL takes a table lock until the test's transaction rolls back.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Repo.Migrations.BackfillDestroyingFromFenceColumns, as: Migration
  alias Fountain.Workers.SandboxReaper

  @version 20_260_918_190_000

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20260918190000_backfill_destroying_from_fence_columns.exs",
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

  describe "the backfill" do
    test "stamps each v0.19.0 fence with its own reason and leaves everything else" do
      user = insert_verified_user()

      reset = v019_row(user, "ready", "persistent", reset: 30)
      teardown = v019_row(user, "ready", "ephemeral", reset: 30, teardown: 30)
      # A reset escalated to a teardown on v0.19.0 keeps the reset's older time.
      escalated = v019_row(user, "suspended", "persistent", reset: 90, teardown: 30)
      finished = v019_row(user, "terminated", "persistent", reset: 30)
      failed = v019_row(user, "failed", "ephemeral", reset: 30, teardown: 30)
      unfenced = v019_row(user, "ready", "persistent", [])

      # Fenced again on v0.20.x, which wrote its own stamp and reason.
      stamped = v019_row(user, "ready", "persistent", reset: 30)
      set_raw(stamped, "transition = 'destroying', transition_reason = 'admin_reap'")

      # Touched on v0.20.x, which could not see the fence: a park it abandoned.
      parking = v019_row(user, "suspended", "persistent", reset: 30)
      set_raw(parking, "transition = 'parking'")

      # A reset the reset door would refuse. v0.19.0 cannot produce it; if one
      # exists it must be finished as a teardown, not skipped for ever.
      odd = v019_row(user, "starting", "persistent", reset: 30)

      before = snapshot()
      run_migration(:up)
      after_up = snapshot()

      assert transition(reset) == {"destroying", "reset"}
      assert transition(teardown) == {"destroying", "teardown"}
      assert transition(escalated) == {"destroying", "teardown"}
      assert transition(parking) == {"destroying", "reset"}
      assert transition(odd) == {"destroying", "teardown"}

      assert transition(finished) == {nil, nil}
      assert transition(failed) == {nil, nil}
      assert transition(unfenced) == {nil, nil}
      assert transition(stamped) == {"destroying", "admin_reap"}

      # Only the two stamp columns move: no lease is written, the grace clock
      # is not restarted, and no status changes.
      for {id, row} <- before do
        assert Map.drop(after_up[id], [:transition, :transition_reason]) ==
                 Map.drop(row, [:transition, :transition_reason])
      end

      # `down` is a no-op: the stamps are the requests the columns recorded.
      run_migration(:down)
      assert snapshot() == after_up
    end
  end

  describe "a reset on a machine used since the request" do
    test "is left live and logged, whatever it would have been labelled" do
      user = insert_verified_user()

      # v0.20.0 could not see the fence, and the user went back to work.
      used = v019_row(user, "ready", "persistent", reset: 30)
      turn_at(used, 10)

      # The only turn is older than the request: v0.19.0 work, reset as asked.
      before = v019_row(user, "suspended", "persistent", reset: 30)
      turn_at(before, 60)

      # Bound since the request, but nothing has run on it.
      bound = v019_row(user, "ready", "persistent", reset: 30)
      insert_conversation(user_id: user.id, sandbox: Repo.get!(Sandbox, bound), status: "idle")

      # A reset the odd-shape branch would destroy as a teardown. For a machine
      # used since, a destroy is worse than a wipe, so it is skipped too.
      odd = v019_row(user, "starting", "persistent", reset: 30)
      turn_at(odd, 10)

      # A teardown is finished however recently the machine was used.
      teardown = v019_row(user, "ready", "ephemeral", reset: 30, teardown: 30)
      turn_at(teardown, 10)

      log = run_migration(:up)

      assert transition(used) == {nil, nil}
      assert transition(odd) == {nil, nil}
      assert transition(before) == {"destroying", "reset"}
      assert transition(bound) == {"destroying", "reset"}
      assert transition(teardown) == {"destroying", "teardown"}

      assert log =~ "left sandbox #{used}"
      assert log =~ "left sandbox #{odd}"
      refute log =~ "left sandbox #{before}"
      refute log =~ "left sandbox #{bound}"
      refute log =~ "left sandbox #{teardown}"
      assert log =~ "stamped 3 sandbox(es)"
    end

    test "keeps its running turn through the teardown run" do
      # The review's reproduction: without the skip, this machine was
      # destroyed and the turn interrupted.
      with_sprites_credentials(fn ->
        user = insert_verified_user()
        home = v019_row(user, "ready", "persistent", reset: 60)
        running = turn_at(home, 5, status: "running")
        destroys = capture_destroys()

        run_migration(:up)

        capture_log(fn ->
          assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
        end)

        assert %Sandbox{status: "ready", transition: nil} = Repo.get!(Sandbox, home)
        assert Repo.reload(running).status == "running"
        assert destroys.() == []
        assert [] = audits(user, "sandbox.reset", home)
      end)
    end
  end

  describe "a turn admitted while the backfill runs" do
    # A rolling upgrade: a v0.20.0 replica admits a turn on a fenced machine
    # while the migration runs. Admission (`_unsafe_create_turn_on_sandbox/4`)
    # takes the sandbox row `FOR SHARE`, inserts the turn, then commits. The
    # migration must wait for it and then see the turn.
    #
    # Two independent connections, committed rows, and a private schema so
    # nothing is left in the shared tables. The schema carries only the
    # columns the migration reads, because what is under test is how two
    # transactions interleave, not the application's schema. The order is
    # forced rather than timed: the migration is started only after the
    # admission holds its lock, and the admission commits only once
    # `pg_blocking_pids/1` shows the migration waiting on it.
    test "is seen, and the reset is left alone" do
      schema = "backfill_race_#{System.unique_integer([:positive])}"
      home = Ecto.UUID.generate()
      conversation = Ecto.UUID.generate()

      committed(fn -> create_race_schema(schema, home, conversation) end)

      # In `on_exit`, which runs even when a crashed task takes the test
      # process down with it.
      on_exit(fn ->
        committed(fn -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE)) end)
      end)

      owner = self()

      admission =
        independent(fn ->
          Repo.transaction(fn ->
            Repo.query!(~s(SET LOCAL search_path TO "#{schema}"))

            Repo.query!("SELECT id FROM sandboxes WHERE id = $1 FOR SHARE", [dump(home)])

            Repo.query!(
              """
              INSERT INTO turns (id, conversation_id, status, inserted_at)
              VALUES ($1, $2, 'running', date_trunc('second', timezone('UTC', now())))
              """,
              [dump(Ecto.UUID.generate()), dump(conversation)]
            )

            send(owner, :admitted)

            receive do
              :commit -> :ok
            after
              5_000 -> raise "the admission was never released"
            end
          end)
        end)

      assert_receive {:backend, _, _}, 5_000
      assert_receive :admitted, 5_000

      {_, log} =
        with_log(fn ->
          migration =
            independent(fn ->
              Repo.transaction(fn ->
                Repo.query!(~s(SET LOCAL search_path TO "#{schema}"))
                run_migration_unlogged(:up)
              end)
            end)

          try do
            assert_receive {:backend, _, backend}, 5_000
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
            send(admission.pid, :commit)
            assert {:ok, :ok} = Task.await(admission)
            assert {:ok, _} = Task.await(migration)
          after
            Task.shutdown(migration, :brutal_kill)
          end
        end)

      assert committed(fn ->
               Repo.query!(
                 ~s(SELECT transition, transition_reason FROM "#{schema}".sandboxes WHERE id = $1),
                 [dump(home)]
               ).rows
             end) == [[nil, nil]]

      assert log =~ "left sandbox #{home}"
    end
  end

  describe "the teardown run over the backfilled rows" do
    test "retries the reset at once and finishes the teardown past its grace" do
      with_sprites_credentials(fn ->
        user = insert_verified_user()
        reset = v019_row(user, "ready", "persistent", reset: 60)
        teardown = v019_row(user, "ready", "ephemeral", reset: 60, teardown: 60)
        unfenced = v019_row(user, "ready", "persistent", [])
        destroys = capture_destroys()

        run_migration(:up)

        capture_log(fn ->
          assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
        end)

        assert Repo.get!(Sandbox, reset).status == "terminated"
        assert Repo.get!(Sandbox, teardown).status == "terminated"
        assert Repo.get!(Sandbox, unfenced).status == "ready"
        assert Enum.sort(destroys.()) == Enum.sort([name(reset), name(teardown)])

        # The reset finishes through the reset's own door, which records the
        # reset and silences the destroy's own event. The teardown finishes
        # through the owner, and its `sandbox.destroyed` carries the reason the
        # fence meant. A reset labelled as a teardown would fail both halves.
        assert [completed] = audits(user, "sandbox.reset", reset)
        assert completed.actor == "system:sandbox_reaper"
        assert completed.metadata["reason"] == "reset_reconciled"
        assert [] = audits(user, "sandbox.destroyed", reset)

        assert [destroyed] = audits(user, "sandbox.destroyed", teardown)
        assert destroyed.metadata["reason"] == "teardown"
        assert destroyed.actor == "system:sandbox_reaper"
        assert [] = audits(user, "sandbox.reset", teardown)

        # The label the backfill stored, as the teardown run read it. The
        # destroyed event alone cannot show it: `Destroy.reason_from_string/1`
        # answers `:teardown` for a null or unknown label too.
        assert [reconciled] = audits(user, "sandbox.teardown_reconciled", teardown)
        assert reconciled.metadata["transition_reason"] == "teardown"
      end)
    end

    test "a reset fenced a minute before the upgrade is retried on the first run" do
      # A reset has no grace window, so a recent request is not held back the
      # way a recent teardown is.
      with_sprites_credentials(fn ->
        user = insert_verified_user()
        reset = v019_row(user, "ready", "persistent", reset: 1)
        destroys = capture_destroys()

        run_migration(:up)

        capture_log(fn ->
          assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
        end)

        assert Repo.get!(Sandbox, reset).status == "terminated"
        assert destroys.() == [name(reset)]
        assert [_] = audits(user, "sandbox.reset", reset)
      end)
    end

    test "a teardown fenced shortly before the upgrade waits out its grace, then goes" do
      # The window reads `updated_at`, which the backfill leaves where v0.19.0's
      # fence put it. A recent fence waits for the rest of its window, and is
      # not skipped for ever.
      with_sprites_credentials(fn ->
        user = insert_verified_user()
        teardown = v019_row(user, "ready", "ephemeral", reset: 5, teardown: 5)
        destroys = capture_destroys()

        run_migration(:up)

        capture_log(fn -> assert {0, 0} = SandboxReaper.sweep_fenced_teardowns() end)
        assert Repo.get!(Sandbox, teardown).status == "ready"
        assert destroys.() == []

        set_raw(teardown, "updated_at = timezone('UTC', now()) - interval '20 minutes'")

        capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)
        assert Repo.get!(Sandbox, teardown).status == "terminated"
        assert destroys.() == [name(teardown)]
      end)
    end
  end

  # A row as v0.19.0 left it: `updated_at` is the fence's own write, and
  # `transition`, `transition_reason` and the lease are what the lease
  # migration adds to a row it did not write.
  defp v019_row(user, status, mode, fences) do
    # An agent each, since a user has one live home per agent.
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

  # A turn on a conversation bound to the sandbox, inserted `minutes` ago.
  # `turns.inserted_at` is stored to the second, like the real column.
  defp turn_at(sandbox_id, minutes, attrs \\ []) do
    sandbox = Repo.get!(Sandbox, sandbox_id)
    conv = insert_conversation(user_id: sandbox.user_id, sandbox: sandbox, status: "idle")
    turn = insert_turn(conv, Map.new(attrs))

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

  defp set_raw(id, assignments) do
    Repo.query!("UPDATE sandboxes SET #{assignments} WHERE id = $1", [dump(id)])
  end

  defp transition(id) do
    %{rows: [row]} =
      Repo.query!("SELECT transition, transition_reason FROM sandboxes WHERE id = $1", [dump(id)])

    List.to_tuple(row)
  end

  defp snapshot do
    %{columns: columns, rows: rows} =
      Repo.query!("""
      SELECT id::text, status, mode, transition, transition_reason, lease_node,
             lease_until, lease_epoch, updated_at, reset_requested_at,
             teardown_requested_at
        FROM sandboxes
      """)

    keys = Enum.map(columns, &String.to_atom/1)
    Map.new(rows, fn [id | _] = row -> {id, Map.new(Enum.zip(keys, row))} end)
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

  # One v0.19.0 reset on a persistent `ready` home, fenced 30 minutes ago, with
  # a conversation bound to it and no turn yet.
  defp create_race_schema(schema, home, conversation) do
    Repo.query!(~s(CREATE SCHEMA "#{schema}"))

    Repo.query!("""
    CREATE TABLE "#{schema}".sandboxes (
      id uuid PRIMARY KEY, user_id uuid, provider text, sprite_name text,
      mode text, status text, transition text, transition_reason text,
      reset_requested_at timestamp(6), teardown_requested_at timestamp(6),
      updated_at timestamp(0)
    )
    """)

    Repo.query!(~s[CREATE TABLE "#{schema}".conversations (id uuid PRIMARY KEY, sandbox_id uuid)])

    Repo.query!("""
    CREATE TABLE "#{schema}".turns (
      id uuid PRIMARY KEY, conversation_id uuid, status text, inserted_at timestamp(0)
    )
    """)

    Repo.query!(
      """
      INSERT INTO "#{schema}".sandboxes
        (id, user_id, provider, sprite_name, mode, status, reset_requested_at)
      VALUES ($1, $2, 'sprites', 'race-home', 'persistent', 'ready',
              timezone('UTC', now()) - interval '30 minutes')
      """,
      [dump(home), dump(Ecto.UUID.generate())]
    )

    Repo.query!(~s[INSERT INTO "#{schema}".conversations VALUES ($1, $2)], [
      dump(conversation),
      dump(home)
    ])
  end

  # Outside the test's sandbox transaction, so the other connections see it.
  defp committed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  # A connection of its own, as in `inference_source_write_order_test.exs`.
  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      committed(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} =
      committed(fn ->
        Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])
      end)

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "the migration did not wait on the admission's lock"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  defp run_migration(direction), do: capture_log(fn -> run_migration_unlogged(direction) end)

  defp run_migration_unlogged(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      Migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end
end
