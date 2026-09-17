defmodule Fountain.Machines.OccupancyTest do
  @moduledoc """
  The one reading of a machine (ADR 0058 stage 4, #2255 decision 1), and the
  four answers taken from it.

  The point of the module is that the four used to be four queries; the point
  of this file is that collapsing the *reading* did not collapse the
  *verdicts*. Every test that distinguishes two of them — a bound conversation
  with no server, a live conversation whose last turn fell outside the idle
  window — is a test that the collapse did not go one step too far.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Lifecycle, Turn}
  alias Fountain.Machines.Occupancy
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

  defp old_turn(conv, ago) do
    at = DateTime.add(now(), -ago, :second)

    conv
    |> insert_turn(%{status: "completed", prompt: "done", started_at: at, ended_at: at})
    |> Ecto.Changeset.change(inserted_at: at)
    |> Repo.update!()
  end

  # A plain process standing in for a conversation's server: `whereis/1` only
  # asks the registry, so registering under the conversation id is all the
  # liveness scan can see of a real one.
  defp stand_in_server(conv_id) do
    test = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv_id, nil)
           send(test, :registered)

           receive do
             :stop -> :ok
           end
         end},
        id: {:stand_in, conv_id}
      )

    assert_receive :registered, 2_000
    # Registration can precede lookup visibility in Horde's CRDT.
    assert {:ok, ^pid} =
             Fountain.Conversations.ConversationServer.await_registered(conv_id, 2_000)

    pid
  end

  defp preloaded(sandbox), do: Repo.preload(sandbox, :conversations, force: true)

  # Every SQL statement `fun` caused, in order. Counting queries is the only
  # way to assert "runs no query at all" — the property that keeps
  # `any_server_alive?/1` usable inside the reaper's per-row scans — and the
  # only way to catch a cheap path quietly becoming an expensive one.
  #
  # A telemetry handler is global (it fires for every query in the VM), and
  # this file is `async: true`, so the handler records only what *this* test
  # process ran — otherwise a concurrent test's queries would land in the
  # count. Ecto emits the event from the process that issued the query, and
  # every path measured here is synchronous on the caller's connection, so the
  # filter sees all of it. A path that ever queried from a child process would
  # go uncounted; if one appears, match `Process.get(:"$callers")` too rather
  # than trusting a zero.
  defp count_queries(fun) do
    me = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:fountain, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == me, do: send(me, {:query, meta.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the struct" do
    test "load/1 reads the bound conversations, the turns and the last activity", ctx do
      turn = insert_turn(ctx.b, %{status: "running", prompt: "go", started_at: now()})

      occ = Occupancy.load(ctx.sandbox.id)

      assert Enum.sort(occ.bound) == Enum.sort([ctx.a.id, ctx.b.id])
      assert occ.running_turns == %{ctx.b.id => "opencode"}
      assert occ.live == []
      assert DateTime.compare(occ.last_activity_at, turn.started_at) in [:eq, :gt]
    end

    test "a terminated conversation is not bound, and its turns still date the machine", ctx do
      old_turn(ctx.b, 30)
      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})

      occ = Occupancy.load(ctx.sandbox.id)

      assert occ.bound == [ctx.a.id]
      assert occ.running_turns == %{}
    end

    test "last_activity_at falls back to the sandbox's own clock", ctx do
      occ = Occupancy.load(ctx.sandbox.id)

      assert DateTime.compare(occ.last_activity_at, ctx.sandbox.inserted_at) == :eq
    end

    test "load/1 on a sandbox that does not exist is empty rather than an error" do
      occ = Occupancy.load(Ecto.UUID.generate())

      assert occ.bound == []
      assert occ.live == []
      assert occ.running_turns == %{}
      assert occ.last_activity_at == nil
    end

    test "a field a constructor did not fill raises rather than reading as empty", ctx do
      occ = Occupancy.bindings(ctx.sandbox.id)

      assert Enum.sort(occ.bound) == Enum.sort([ctx.a.id, ctx.b.id])

      assert_raise ArgumentError, ~r/live_ids\/1 needs :live/, fn -> Occupancy.live_ids(occ) end

      assert_raise ArgumentError, ~r/busy_elsewhere\?\/4 needs :activity/, fn ->
        Occupancy.busy_elsewhere?(occ, ctx.a.id, 3600, now())
      end
    end
  end

  describe "held_by_other?/2 — status only" do
    test "a co-tenant holds the machine however long it has been quiet", ctx do
      ctx.b
      |> Ecto.Changeset.change(updated_at: DateTime.add(now(), -99_999, :second))
      |> Repo.update!()

      assert ctx.sandbox.id |> Occupancy.bindings() |> Occupancy.held_by_other?(ctx.a.id)
    end

    test "a terminated co-tenant does not", ctx do
      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})

      refute ctx.sandbox.id |> Occupancy.bindings() |> Occupancy.held_by_other?(ctx.a.id)
    end
  end

  describe "busy_elsewhere?/4 — status and the idle window" do
    test "a machine held by a long-quiet co-tenant is not busy", ctx do
      # The case that separates this predicate from held_by_other?/2: both
      # read the same `bound`, and they disagree about it on purpose.
      old_turn(ctx.b, 7200)

      occ = Occupancy.load(ctx.sandbox.id)

      assert Occupancy.held_by_other?(occ, ctx.a.id)
      refute Occupancy.busy_elsewhere?(occ, ctx.a.id, 3600, now())
    end

    test "a co-tenant mid-turn is busy however old the turn is", ctx do
      old = DateTime.add(now(), -99_999, :second)

      ctx.b
      |> insert_turn(%{status: "running", prompt: "go", started_at: old})
      |> Ecto.Changeset.change(inserted_at: old)
      |> Repo.update!()

      occ = Occupancy.load(ctx.sandbox.id)

      assert Occupancy.busy_elsewhere?(occ, ctx.a.id, 3600, now())
    end

    test "a co-tenant that finished a turn inside the window is busy", ctx do
      old_turn(ctx.b, 60)

      assert ctx.sandbox.id
             |> Occupancy.load()
             |> Occupancy.busy_elsewhere?(ctx.a.id, 3600, now())
    end

    test "a co-tenant that never took a turn counts by its own row's age", ctx do
      assert ctx.sandbox.id
             |> Occupancy.load()
             |> Occupancy.busy_elsewhere?(ctx.a.id, 3600, now())

      ctx.b
      |> Ecto.Changeset.change(updated_at: DateTime.add(now(), -7200, :second))
      |> Repo.update!()

      refute ctx.sandbox.id
             |> Occupancy.load()
             |> Occupancy.busy_elsewhere?(ctx.a.id, 3600, now())
    end

    test "a co-tenant with only old turns is judged by them, not by its own row", ctx do
      # `conversations.updated_at` moves for bookkeeping the user had nothing
      # to do with — the rehydrator touches it on every boot — so a
      # conversation that HAS turns must never fall back to it.
      old_turn(ctx.b, 7200)
      ctx.b |> Ecto.Changeset.change(updated_at: now()) |> Repo.update!()

      refute ctx.sandbox.id
             |> Occupancy.load()
             |> Occupancy.busy_elsewhere?(ctx.a.id, 3600, now())
    end

    test "this conversation's own activity does not count", ctx do
      insert_turn(ctx.a, %{status: "running", prompt: "go", started_at: now()})

      ctx.b
      |> Ecto.Changeset.change(updated_at: DateTime.add(now(), -7200, :second))
      |> Repo.update!()

      refute ctx.sandbox.id
             |> Occupancy.load()
             |> Occupancy.busy_elsewhere?(ctx.a.id, 3600, now())
    end

    test "the bound switched off is never busy", ctx do
      insert_turn(ctx.b, %{status: "running", prompt: "go", started_at: now()})

      refute ctx.sandbox.id |> Occupancy.load() |> Occupancy.busy_elsewhere?(ctx.a.id, nil, now())
    end

    test "nil idle seconds short-circuits before the struct is even read", ctx do
      # `_unsafe_sandbox_busy_elsewhere?/4` answers false on a nil bound
      # without touching the database, and the delegation keeps that: an
      # unloaded struct must not raise here.
      refute Occupancy.bindings(ctx.sandbox.id)
             |> Occupancy.busy_elsewhere?(ctx.a.id, nil, now())
    end
  end

  describe "live_ids/1 and any_live?/1 — the registry" do
    test "a bound conversation with no registered server is not live", ctx do
      occ = Occupancy.load(ctx.sandbox.id)

      assert Enum.sort(occ.bound) == Enum.sort([ctx.a.id, ctx.b.id])
      assert Occupancy.live_ids(occ) == []
      refute Occupancy.any_live?(occ)
    end

    test "a registered server is live, from the rows or from a preload", ctx do
      stand_in_server(ctx.b.id)

      assert Occupancy.live_ids(Occupancy.load(ctx.sandbox.id)) == [ctx.b.id]

      occ = ctx.sandbox |> preloaded() |> Occupancy.from_preloaded()
      assert Occupancy.live_ids(occ) == [ctx.b.id]
      assert Occupancy.any_live?(occ)
    end

    test "a terminated conversation whose server is still registered stays live", ctx do
      # Deliberate, and load-bearing: the reaper reads a registered server as
      # "something is still in flight somewhere in the cluster, do not touch
      # this row", whatever the conversation's status says. `live` is
      # therefore not a subset of `bound`.
      stand_in_server(ctx.b.id)
      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})

      occ = ctx.sandbox |> preloaded() |> Occupancy.from_preloaded()

      assert occ.bound == [ctx.a.id]
      assert Occupancy.live_ids(occ) == [ctx.b.id]
      assert Occupancy.any_live?(occ)
    end

    test "from_preloaded/1 runs no query at all", ctx do
      sandbox = preloaded(ctx.sandbox)

      {occ, queries} = count_queries(fn -> Occupancy.from_preloaded(sandbox) end)

      assert queries == [], "expected no query, got:\n#{Enum.join(queries, "\n")}"
      assert Enum.sort(occ.bound) == Enum.sort([ctx.a.id, ctx.b.id])
      assert occ.activity == :unloaded
      assert occ.running_turns == :unloaded
    end

    test "the zero-query path survives into the reaper's two callers", ctx do
      # `Lifecycle.any_server_alive?/1` sits inside three `SandboxReaper`
      # scans, once per candidate row. A query added here would be an N+1 in
      # a sweep over every ready sandbox in the fleet, and nothing else in
      # the suite would notice.
      sandbox = preloaded(ctx.sandbox)

      {_, live} = count_queries(fn -> Lifecycle.live_conversation_ids(sandbox) end)
      {_, alive} = count_queries(fn -> Lifecycle.any_server_alive?(sandbox) end)

      assert live == [], Enum.join(live, "\n")
      assert alive == [], Enum.join(alive, "\n")
    end
  end

  describe "what each path costs" do
    # The predicates differ in cost as deliberately as they differ in meaning,
    # and the cheap ones are cheap because of where they are called from. A
    # refactor that collapses them is exactly what these numbers catch.
    setup ctx do
      # Five conversations, four turns each: enough that a rollup over every
      # turn on the machine is visibly not what the cheap path does.
      for _ <- 1..3 do
        conv =
          insert_conversation(
            user_id: ctx.user.id,
            agent: ctx.agent,
            sandbox: ctx.sandbox,
            status: "idle"
          )

        for _ <- 1..4, do: insert_turn(conv, %{status: "completed", prompt: "x"})
      end

      :ok
    end

    test "bindings/1 and the two predicates on it run one query each", ctx do
      {_, bindings} = count_queries(fn -> Occupancy.bindings(ctx.sandbox.id) end)

      {_, held} =
        count_queries(fn ->
          Fountain.Machines.Binding.held_by_other?(ctx.sandbox.id, ctx.a.id)
        end)

      {_, cotenants} =
        count_queries(fn ->
          Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, ctx.a.id)
        end)

      assert length(bindings) == 1, Enum.join(bindings, "\n")
      assert length(held) == 1, Enum.join(held, "\n")
      assert length(cotenants) == 1, Enum.join(cotenants, "\n")
    end

    test "busy_elsewhere?/4 by id short-circuits and never reads the sandbox row", ctx do
      insert_turn(ctx.b, %{status: "running", prompt: "go", started_at: now()})

      {result, queries} =
        count_queries(fn ->
          Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
        end)

      assert result

      # The co-tenant probe plus one EXISTS that stopped at the running turn.
      # The second EXISTS never runs, because the first answered.
      assert length(queries) == 2, Enum.join(queries, "\n")

      # This is on the conversation server's lifecycle tick. The sandbox row
      # is only wanted for `last_activity_at`, which this predicate never
      # reads, and a GROUP BY over every turn on the machine is the opposite
      # of a short circuit.
      refute Enum.any?(queries, &String.contains?(&1, ~s(FROM "sandboxes")))
      refute Enum.any?(queries, &String.contains?(&1, "GROUP BY"))
    end

    test "load/1 pays for the whole reading, because the owner wants it", ctx do
      {_, queries} = count_queries(fn -> Occupancy.load(ctx.sandbox.id) end)

      assert length(queries) == 3, Enum.join(queries, "\n")
    end
  end

  describe "the two forms of busy_elsewhere?/4 agree with the query they replaced" do
    # A differential check against `_unsafe_sandbox_busy_elsewhere?/4` as it
    # stood at `adr/0058-machine-owner`, copied verbatim into `old/4` below.
    # Both new forms — by id and from a loaded struct — must match it on every
    # edge the semantics have. The struct form folds the query's per-row
    # disjunction into per-conversation maxima, which is only sound because
    # `∃r (P ∨ Q ∨ R) ≡ (∃r P) ∨ (∃r Q) ∨ (∃r R)` and `max(x) > c ≡ ∃x > c`
    # with NULLs dropped; these cases are what hold that reasoning to account.

    defp old(_sandbox_id, _conv_id, nil, _now), do: false

    defp old(sandbox_id, conv_id, idle_seconds, now) when is_integer(idle_seconds) do
      cutoff = now |> DateTime.add(-idle_seconds, :second) |> DateTime.truncate(:second)

      cotenants =
        Repo.all(
          from c in Conversation,
            where:
              c.sandbox_id == ^sandbox_id and c.id != ^conv_id and
                c.status not in ["terminated", "failed"],
            select: c.id
        )

      case cotenants do
        [] ->
          false

        cotenants ->
          Repo.exists?(
            from t in Turn,
              where:
                t.conversation_id in ^cotenants and
                  (t.status == "running" or t.inserted_at > ^cutoff or t.ended_at > ^cutoff)
          ) or
            Repo.exists?(
              from c in Conversation,
                left_join: t in Turn,
                on: t.conversation_id == c.id,
                where: c.id in ^cotenants and is_nil(t.id) and c.updated_at > ^cutoff
            )
      end
    end

    # Asserts all three agree, and returns the verdict so the caller can pin
    # which way it went — "they agree on false" is only half a test.
    defp agree(sandbox_id, conv_id, idle, now) do
      was = old(sandbox_id, conv_id, idle, now)
      by_id = Occupancy.busy_elsewhere?(sandbox_id, conv_id, idle, now)

      from_struct =
        sandbox_id |> Occupancy.load() |> Occupancy.busy_elsewhere?(conv_id, idle, now)

      assert by_id == was, "by-id diverged: was #{inspect(was)}, now #{inspect(by_id)}"

      assert from_struct == was,
             "struct form diverged: was #{inspect(was)}, now #{inspect(from_struct)}"

      was
    end

    defp stamped(conv, attrs, inserted_at) do
      conv
      |> insert_turn(attrs)
      |> Ecto.Changeset.change(inserted_at: inserted_at)
      |> Repo.update!()
    end

    test "a nil ended_at on a non-running turn, inside and outside the window", ctx do
      t = now()
      old_at = DateTime.add(t, -7200, :second)

      stamped(ctx.b, %{status: "failed", prompt: "x", started_at: old_at, ended_at: nil}, old_at)
      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)

      stamped(ctx.b, %{status: "failed", prompt: "y", started_at: t, ended_at: nil}, t)
      assert agree(ctx.sandbox.id, ctx.a.id, 3600, t)
    end

    test "a timestamp exactly on the cutoff is not inside the window", ctx do
      t = now()
      cutoff = DateTime.add(t, -3600, :second)

      stamped(ctx.b, %{status: "completed", prompt: "x", ended_at: cutoff}, cutoff)
      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)

      # One second later is.
      refute agree(ctx.sandbox.id, ctx.a.id, 3599, t)
      assert agree(ctx.sandbox.id, ctx.a.id, 3601, t)
    end

    test "the disjunction split across two turn rows, both ways round", ctx do
      t = now()
      old_at = DateTime.add(t, -7200, :second)
      recent = DateTime.add(t, -60, :second)

      # Row 1 inserted recently but ended long ago; row 2 the reverse. Neither
      # row satisfies both halves, and the answer is still busy.
      stamped(ctx.b, %{status: "completed", prompt: "x", ended_at: old_at}, recent)
      assert agree(ctx.sandbox.id, ctx.a.id, 3600, t)

      other =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "idle"
        )

      stamped(other, %{status: "completed", prompt: "y", ended_at: recent}, old_at)
      assert agree(ctx.sandbox.id, ctx.a.id, 3600, t)
    end

    test "a terminated co-tenant carrying a running turn row does not count", ctx do
      t = now()
      insert_turn(ctx.b, %{status: "running", prompt: "go", started_at: t})
      assert agree(ctx.sandbox.id, ctx.a.id, 3600, t)

      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})
      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)

      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "failed"})
      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)
    end

    test "turns on a conversation bound to another sandbox never count", ctx do
      t = now()
      elsewhere = insert_sandbox(user_id: ctx.user.id, status: "ready")

      stranger =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: elsewhere,
          status: "idle"
        )

      insert_turn(stranger, %{status: "running", prompt: "go", started_at: t})

      ctx.b
      |> Ecto.Changeset.change(updated_at: DateTime.add(t, -7200, :second))
      |> Repo.update!()

      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)
    end

    test "idle seconds of nil and of zero", ctx do
      t = now()
      insert_turn(ctx.b, %{status: "running", prompt: "go", started_at: t})

      refute agree(ctx.sandbox.id, ctx.a.id, nil, t)
      # A zero window still sees a running turn: mid-turn is not a clock
      # question.
      assert agree(ctx.sandbox.id, ctx.a.id, 0, t)
    end

    test "three co-tenants with only the third busy", ctx do
      t = now()
      stale = DateTime.add(t, -7200, :second)

      for conv <- [ctx.b] do
        conv |> Ecto.Changeset.change(updated_at: stale) |> Repo.update!()
      end

      quiet =
        for _ <- 1..2 do
          conv =
            insert_conversation(
              user_id: ctx.user.id,
              agent: ctx.agent,
              sandbox: ctx.sandbox,
              status: "idle"
            )

          stamped(conv, %{status: "completed", prompt: "x", ended_at: stale}, stale)
          conv
        end

      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)

      [_, third] = quiet
      insert_turn(third, %{status: "running", prompt: "go", started_at: t})
      assert agree(ctx.sandbox.id, ctx.a.id, 3600, t)
    end

    test "no co-tenants at all", ctx do
      t = now()
      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})

      refute agree(ctx.sandbox.id, ctx.a.id, 3600, t)
    end
  end
end
