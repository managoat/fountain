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

      # Nothing to assert about SQL from here, so assert the shape that makes
      # it true: the association is read, never fetched.
      occ = Occupancy.from_preloaded(sandbox)

      assert Enum.sort(occ.bound) == Enum.sort([ctx.a.id, ctx.b.id])
      assert occ.activity == :unloaded
      assert occ.running_turns == :unloaded
    end
  end
end
