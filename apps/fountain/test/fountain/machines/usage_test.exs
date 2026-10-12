defmodule Fountain.Machines.UsageTest do
  @moduledoc """
  Provider spend attribution: which tenant, on which provider, ran how long.

  The cases that matter here are the ones the old terminate-only accrual got
  wrong — a sandbox that outlives the period, one that starts before it, one
  still running — because those are exactly the sandboxes a provider invoice
  is mostly made of.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Usage
  alias Fountain.Machines.Usage, as: SandboxUsage
  alias Fountain.Usage.Event, as: UsageEvent
  alias Fountain.Conversations
  alias Fountain.Repo

  @period_start ~U[2026-05-01 00:00:00Z]
  @period_end ~U[2026-06-01 00:00:00Z]
  # Well past period_end, so the ceiling is the period rather than the clock.
  @now ~U[2026-07-01 00:00:00Z]

  defp attribution(opts \\ []) do
    SandboxUsage.attribution(@period_start, @period_end, Keyword.put_new(opts, :now, @now))
  end

  defp seconds_for(rows, user_id, provider) do
    case Enum.find(rows, &(&1.user_id == user_id and &1.provider == provider)) do
      nil -> nil
      row -> row.active_seconds
    end
  end

  defp terminated_sandbox(user, provider, started, ended) do
    insert_sandbox(
      user_id: user.id,
      provider: provider,
      status: "terminated",
      inserted_at: started,
      terminated_at: ended
    )
  end

  defp park_event(sandbox, type, at) do
    Repo.insert!(%UsageEvent{
      user_id: sandbox.user_id,
      event_type: type,
      resource_id: sandbox.id,
      resource_type: "sandbox",
      metadata: %{},
      inserted_at: at
    })
  end

  describe "attribution/3" do
    test "attributes a sandbox's seconds to its owner and its provider" do
      user = insert_verified_user()

      terminated_sandbox(user, "e2b", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      assert [row] = attribution()
      assert row.user_id == user.id
      assert row.provider == "e2b"
      assert row.active_seconds == 3600
      assert row.sandboxes == 1
    end

    test "keeps two providers apart for the same tenant" do
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:10:00Z])
      terminated_sandbox(user, "daytona", ~U[2026-05-03 00:00:00Z], ~U[2026-05-03 00:30:00Z])

      rows = attribution()

      assert seconds_for(rows, user.id, "sprites") == 600
      assert seconds_for(rows, user.id, "daytona") == 1800
    end

    test "keeps two tenants apart on the same provider" do
      one = insert_verified_user()
      two = insert_verified_user()

      terminated_sandbox(one, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:10:00Z])
      terminated_sandbox(two, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:20:00Z])

      rows = attribution()

      assert seconds_for(rows, one.id, "sprites") == 600
      assert seconds_for(rows, two.id, "sprites") == 1200
    end

    test "counts several sandboxes of one tenant as one row with a sandbox count" do
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:10:00Z])
      terminated_sandbox(user, "sprites", ~U[2026-05-04 00:00:00Z], ~U[2026-05-04 00:10:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 1200
      assert row.sandboxes == 2
    end

    test "counts only the part of a sandbox that ran inside the period" do
      # Runs from a week before the period to a week into it: the month is
      # charged for its week, not for the whole fifteen days.
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-04-24 00:00:00Z], ~U[2026-05-08 00:00:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 7 * 24 * 3600
    end

    test "counts a sandbox that outlives the period up to period_end, not beyond" do
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-05-30 00:00:00Z], ~U[2026-06-15 00:00:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 2 * 24 * 3600
    end

    test "counts a sandbox that is still running — the terminate-only gap" do
      user = insert_verified_user()

      insert_sandbox(
        user_id: user.id,
        provider: "sprites",
        status: "ready",
        inserted_at: ~U[2026-05-20 00:00:00Z]
      )

      assert [row] = attribution()
      assert row.active_seconds == 12 * 24 * 3600
    end

    test "a still-running sandbox accrues only up to now, never past it" do
      # Asked about the current month mid-month, the answer is what has been
      # spent so far — not what the month will cost if nothing changes.
      user = insert_verified_user()

      insert_sandbox(
        user_id: user.id,
        provider: "sprites",
        status: "ready",
        inserted_at: ~U[2026-05-20 00:00:00Z]
      )

      assert [row] =
               SandboxUsage.attribution(@period_start, @period_end, now: ~U[2026-05-22 00:00:00Z])

      assert row.active_seconds == 2 * 24 * 3600
    end

    test "ignores a sandbox that ended before the period" do
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-04-01 00:00:00Z], ~U[2026-04-02 00:00:00Z])

      assert attribution() == []
    end

    test "ignores a sandbox that started after the period" do
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-06-02 00:00:00Z], ~U[2026-06-03 00:00:00Z])

      assert attribution() == []
    end

    test "falls back to updated_at for a terminal row with no terminated_at" do
      # Failed sandboxes never carried a terminated_at before the backfill.
      # Without the fallback such a row reads as still running and accrues to
      # the end of every period, forever.
      user = insert_verified_user()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          provider: "sprites",
          status: "failed",
          inserted_at: ~U[2026-05-10 12:00:00Z]
        )

      Repo.update_all(
        from(s in Fountain.Conversations.Sandbox, where: s.id == ^sandbox.id),
        set: [terminated_at: nil, updated_at: ~U[2026-05-10 12:05:00Z]]
      )

      assert [row] = attribution()
      assert row.active_seconds == 300
    end

    test "scopes to one tenant with :user_id" do
      one = insert_verified_user()
      two = insert_verified_user()

      terminated_sandbox(one, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:10:00Z])
      terminated_sandbox(two, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:20:00Z])

      assert [row] = attribution(user_id: one.id)
      assert row.user_id == one.id
      assert row.active_seconds == 600
    end
  end

  describe "attribution/3 — parked time" do
    test "subtracts a suspend/resume interval" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      park_event(sandbox, "sandbox_suspended", ~U[2026-05-10 12:15:00Z])
      park_event(sandbox, "sandbox_resumed", ~U[2026-05-10 12:45:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 1800
    end

    test "closes a suspend that never resumed at the sandbox's own end" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      park_event(sandbox, "sandbox_suspended", ~U[2026-05-10 12:30:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 1800
    end

    test "closes a still-parked sandbox's suspend at the period's end" do
      user = insert_verified_user()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          provider: "sprites",
          status: "suspended",
          inserted_at: ~U[2026-05-29 00:00:00Z]
        )

      park_event(sandbox, "sandbox_suspended", ~U[2026-05-30 00:00:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 24 * 3600
    end

    test "clips a parked interval that starts before the period" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-04-25 00:00:00Z], ~U[2026-05-03 00:00:00Z])

      park_event(sandbox, "sandbox_suspended", ~U[2026-04-28 00:00:00Z])
      park_event(sandbox, "sandbox_resumed", ~U[2026-05-02 00:00:00Z])

      # In-period lifetime is 2 days (May 1–3); the first of them was parked.
      assert [row] = attribution()
      assert row.active_seconds == 24 * 3600
    end

    test "never reports negative seconds when parked time covers the whole period" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-04-01 00:00:00Z], ~U[2026-06-15 00:00:00Z])

      park_event(sandbox, "sandbox_suspended", ~U[2026-04-02 00:00:00Z])
      park_event(sandbox, "sandbox_resumed", ~U[2026-06-14 00:00:00Z])

      assert seconds_for(attribution(), user.id, "sprites") == 0
    end
  end

  describe "attribution/3 — idle time" do
    # A sandbox nobody is prompting still costs full price, so it stays in
    # active. Reporting it separately is what says whether the bill is
    # avoidable.
    defp turn(sandbox, user, started_at, ended_at, overrides \\ %{}) do
      agent = insert_agent(user_id: user.id)

      conversation =
        insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      attrs =
        Map.merge(
          %{
            conversation_id: conversation.id,
            turn_number: System.unique_integer([:positive]),
            prompt: "hello",
            status: "completed",
            started_at: started_at,
            ended_at: ended_at
          },
          overrides
        )

      {:ok, _} = Conversations._unsafe_create_turn(attrs)
    end

    test "an hour with a ten-minute turn is fifty minutes idle" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:10:00Z], ~U[2026-05-10 12:20:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 3600
      assert row.busy_seconds == 600
      assert row.idle_seconds == 3000
    end

    test "orphaned turns are excluded from busy and turn time" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      turn(
        sandbox,
        user,
        ~U[2026-05-10 12:00:00Z],
        ~U[2026-05-10 13:00:00Z],
        %{status: "interrupted", orphaned_at: ~U[2026-05-10 13:00:00Z]}
      )

      assert [row] = attribution()
      assert row.busy_seconds == 0
      assert row.turn_seconds == 0
      assert row.idle_seconds == row.active_seconds
    end

    test "a sandbox that never took a turn is entirely idle" do
      user = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      assert [row] = attribution()
      assert row.busy_seconds == 0
      assert row.idle_seconds == row.active_seconds
    end

    test "busy and idle always add up to active" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:05:00Z], ~U[2026-05-10 12:15:00Z])
      turn(sandbox, user, ~U[2026-05-10 12:40:00Z], ~U[2026-05-10 12:50:00Z])

      assert [row] = attribution()
      assert row.busy_seconds + row.idle_seconds == row.active_seconds
      assert row.busy_seconds == 1200
    end

    test "overlapping turns on one sandbox count once, not twice" do
      # Two conversations prompting at the same moment is one busy sandbox.
      # Summing them would push busy past active and report negative idle.
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:30:00Z])
      turn(sandbox, user, ~U[2026-05-10 12:10:00Z], ~U[2026-05-10 12:40:00Z])

      assert [row] = attribution()
      assert row.busy_seconds == 2400
      assert row.idle_seconds == 1200
      # The tenant's view is the sum: two half-hour turns are an hour of work,
      # on a machine that was busy for forty minutes (ADR 0023 step 6).
      assert row.turn_seconds == 3600
    end

    test "turn seconds sum per turn and may exceed the machine's active time" do
      # Several conversations on one sandbox at once (ADR 0023): each hour of
      # each turn spends an hour of the allowance, however many share the disk.
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])
      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])
      turn(sandbox, user, ~U[2026-05-10 12:30:00Z], ~U[2026-05-10 13:00:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 3600
      assert row.busy_seconds == 3600
      assert row.idle_seconds == 0
      assert row.turn_seconds == 9000

      assert SandboxUsage.by_provider([row])["sprites"].turn_seconds == 9000

      assert SandboxUsage.turn_seconds_for_user(user.id, @period_start, @period_end) ==
               %{"sprites" => 9000}

      assert SandboxUsage.busy_for_user(user.id, @period_start, @period_end) ==
               %{"sprites" => 3600}

      # Turn hours report the sum.
      assert Usage.usage_summary(user.id, @period_start, @period_end).turn_hours == 2.5
    end

    test "a turn still running is busy up to the ceiling" do
      user = insert_verified_user()

      sandbox =
        insert_sandbox(
          user_id: user.id,
          provider: "sprites",
          status: "ready",
          inserted_at: ~U[2026-05-31 22:00:00Z]
        )

      turn(sandbox, user, ~U[2026-05-31 23:00:00Z], nil)

      assert [row] = attribution()
      assert row.active_seconds == 2 * 3600
      assert row.busy_seconds == 3600
      assert row.idle_seconds == 3600
    end

    test "a turn is clipped to the period, like everything else" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-04-30 22:00:00Z], ~U[2026-05-01 02:00:00Z])

      # Runs from an hour before the period into its first hour.
      turn(sandbox, user, ~U[2026-04-30 23:00:00Z], ~U[2026-05-01 01:00:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 2 * 3600
      assert row.busy_seconds == 3600
    end

    test "parked time is neither busy nor idle — it is not paid for" do
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      park_event(sandbox, "sandbox_suspended", ~U[2026-05-10 12:30:00Z])
      park_event(sandbox, "sandbox_resumed", ~U[2026-05-10 12:45:00Z])
      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:10:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 2700
      assert row.busy_seconds == 600
      assert row.idle_seconds == 2100
    end

    test "never reports negative idle when turns outrun the paid window" do
      # Defensive: a mostly-parked sandbox whose turn rows say it was busy
      # throughout. Busy caps at active rather than going through it.
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      park_event(sandbox, "sandbox_suspended", ~U[2026-05-10 12:05:00Z])
      park_event(sandbox, "sandbox_resumed", ~U[2026-05-10 12:55:00Z])
      turn(sandbox, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      assert [row] = attribution()
      assert row.active_seconds == 600
      assert row.busy_seconds == 600
      assert row.idle_seconds == 0
    end

    test "one sandbox's turns do not make another look busy" do
      user = insert_verified_user()

      busy =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      terminated_sandbox(user, "e2b", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      turn(busy, user, ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:30:00Z])

      rows = attribution()

      assert Enum.find(rows, &(&1.provider == "sprites")).busy_seconds == 1800
      assert Enum.find(rows, &(&1.provider == "e2b")).busy_seconds == 0
    end
  end

  describe "by_provider/1" do
    test "totals seconds, sandboxes and distinct tenants per provider" do
      one = insert_verified_user()
      two = insert_verified_user()

      terminated_sandbox(one, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:10:00Z])
      terminated_sandbox(two, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:20:00Z])
      terminated_sandbox(two, "e2b", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:05:00Z])

      totals = attribution() |> SandboxUsage.by_provider()

      # No turns anywhere, so every paid second is idle.
      assert totals["sprites"] == %{
               active_seconds: 1800,
               busy_seconds: 0,
               idle_seconds: 1800,
               turn_seconds: 0,
               sandboxes: 2,
               users: 2
             }

      assert totals["e2b"] == %{
               active_seconds: 300,
               busy_seconds: 0,
               idle_seconds: 300,
               turn_seconds: 0,
               sandboxes: 1,
               users: 1
             }
    end
  end

  describe "platform_cost?/1" do
    test "the providers the operator pays for" do
      assert SandboxUsage.platform_cost?("sprites")
      assert SandboxUsage.platform_cost?("e2b")
      assert SandboxUsage.platform_cost?("daytona")
    end

    test "a self-hosted runner is the tenant's own machine" do
      refute SandboxUsage.platform_cost?("runner")
    end

    test "an unknown provider is not assumed to be ours" do
      refute SandboxUsage.platform_cost?("something-new")
    end
  end

  describe "for_user/3" do
    test "one tenant's seconds per provider" do
      user = insert_verified_user()
      other = insert_verified_user()

      terminated_sandbox(user, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:10:00Z])
      terminated_sandbox(user, "e2b", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:05:00Z])
      terminated_sandbox(other, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 01:00:00Z])

      assert SandboxUsage.for_user(user.id, @period_start, @period_end) == %{
               "sprites" => 600,
               "e2b" => 300
             }
    end

    test "is empty for a tenant with no sandbox time" do
      user = insert_verified_user()

      assert SandboxUsage.for_user(user.id, @period_start, @period_end) == %{}
    end
  end

  describe "provider_spend/1" do
    test "splits by provider and names the tenants behind the bill" do
      one = insert_verified_user()
      two = insert_verified_user()

      terminated_sandbox(one, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 01:00:00Z])
      terminated_sandbox(two, "e2b", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 00:30:00Z])

      spend = SandboxUsage.provider_spend(period: {@period_start, @period_end}, now: @now)

      assert spend.by_provider["sprites"].active_seconds == 3600
      assert spend.by_provider["e2b"].active_seconds == 1800
      assert spend.platform_seconds == 5400
      # Neither sandbox took a turn, so all of it is time we could not justify.
      assert spend.platform_idle_seconds == 5400

      assert [top, second] = spend.top_tenants
      assert top.email == one.email
      assert top.provider == "sprites"
      assert second.email == two.email
    end

    test "self-hosted runner hours are reported but are not our bill" do
      user = insert_verified_user()

      terminated_sandbox(user, "runner", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 01:00:00Z])

      spend = SandboxUsage.provider_spend(period: {@period_start, @period_end}, now: @now)

      assert spend.by_provider["runner"].active_seconds == 3600
      assert spend.platform_seconds == 0
      assert spend.top_tenants == []
    end

    test "keeps a deleted account's seconds in the provider total" do
      # The platform paid for them; they are simply no longer attributable.
      user = insert_verified_user()

      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-02 00:00:00Z], ~U[2026-05-02 01:00:00Z])

      Repo.update_all(
        from(s in Fountain.Conversations.Sandbox, where: s.id == ^sandbox.id),
        set: [user_id: nil]
      )

      spend = SandboxUsage.provider_spend(period: {@period_start, @period_end}, now: @now)

      assert spend.by_provider["sprites"].active_seconds == 3600
      assert [%{email: nil}] = spend.top_tenants
    end
  end
end
