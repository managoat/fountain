defmodule Fountain.BillingTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Billing
  alias Fountain.Billing.UsageEvent
  alias Fountain.Repo

  describe "usage_summary/3" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "returns zeros when no events exist", %{user: user} do
      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 0
      assert summary.turns == 0
      assert summary.sandbox_minutes == 0.0
    end

    test "a conversation is one that ran a turn; a provision alone is not one", %{user: user} do
      c1 = Ecto.UUID.generate()
      c2 = Ecto.UUID.generate()
      insert_event(user, "sandbox_provisioned", ~U[2026-05-10 12:00:00Z])
      insert_event(user, "sandbox_provision_failed", ~U[2026-05-11 12:00:00Z])
      insert_event(user, "turn_started", ~U[2026-05-10 12:00:00Z], %{"conversation_id" => c1})
      insert_event(user, "turn_started", ~U[2026-05-10 12:05:00Z], %{"conversation_id" => c1})
      insert_event(user, "turn_started", ~U[2026-05-12 12:10:00Z], %{"conversation_id" => c2})

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 2
      assert summary.turns == 3
    end

    test "credit_burned_cents is what the ledger took in the window", %{user: user} do
      {:ok, _} =
        Fountain.Credits.debit(user.id, 40, "burn_turn", idempotency_key: "in-#{user.id}")

      {:ok, _} =
        Fountain.Credits.debit(user.id, 7, "burn_inference", idempotency_key: "in2-#{user.id}")

      now = DateTime.utc_now()
      %{start: s, end: e} = Billing.month_range(0, now: now)
      assert Billing.usage_summary(user.id, s, e).credit_burned_cents == 47
      assert Billing.usage_summary(user.id, @period_start, @period_end).credit_burned_cents == 0
    end

    test "sums the sandboxes' active time into sandbox_minutes", %{user: user} do
      terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:01:00Z])
      terminated_sandbox(user, "sprites", ~U[2026-05-10 12:30:00Z], ~U[2026-05-10 12:32:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 3.0
    end

    test "excludes events outside the period", %{user: user} do
      # One second before period start - excluded
      insert_event(user, "turn_started", ~U[2026-04-30 23:59:59Z], %{"conversation_id" => "a"})
      # Exactly at period_end - excluded (query uses `< ^period_end`)
      insert_event(user, "turn_started", ~U[2026-06-01 00:00:00Z], %{"conversation_id" => "b"})

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 0
      assert summary.turns == 0
      assert summary.sandbox_minutes == 0.0
    end
  end

  describe "month_range/2" do
    test "is half-open: the last second of the month is inside it" do
      now = ~U[2026-02-14 12:00:00Z]
      %{start: s, end: e} = Billing.month_range(0, now: now)
      assert s == ~U[2026-02-01 00:00:00Z]
      assert e == ~U[2026-03-01 00:00:00Z]
      assert DateTime.compare(~U[2026-02-28 23:59:59Z], e) == :lt

      assert %{start: ~U[2025-12-01 00:00:00Z], end: ~U[2026-01-01 00:00:00Z]} =
               Billing.month_range(2, now: now)

      {ts, te} = Billing.current_month_range()
      assert ts.day == 1 and te.day == 1 and te.hour == 0
    end

    test "usage_summary/3 counts an event in the month's last second" do
      user = insert_verified_user()
      %{start: s, end: e} = Billing.month_range(0, now: ~U[2026-02-14 12:00:00Z])

      {:ok, _} =
        Billing.record_usage(user.id, "turn_started", Ecto.UUID.generate(), "conversation")

      Repo.update_all(Fountain.Billing.UsageEvent,
        set: [inserted_at: ~U[2026-02-28 23:59:59Z]]
      )

      assert Billing.usage_summary(user.id, s, e).turns == 1
    end
  end

  describe "emit/5" do
    setup do
      {:ok, user: insert_verified_user()}
    end

    test "inserts a UsageEvent and returns {:ok, event} with correct fields", %{user: user} do
      resource_id = Ecto.UUID.generate()

      assert {:ok, event} =
               Billing.emit(user.id, "sandbox_provisioned", resource_id, "sandbox", %{
                 "foo" => "bar"
               })

      assert event.user_id == user.id
      assert event.event_type == "sandbox_provisioned"
      assert event.resource_id == resource_id
      assert event.resource_type == "sandbox"
      assert event.metadata == %{"foo" => "bar"}
      assert event.id != nil
    end

    test "metadata defaults to %{} when called with arity 4", %{user: user} do
      resource_id = Ecto.UUID.generate()

      assert {:ok, event} = Billing.emit(user.id, "turn_started", resource_id, "conversation")

      assert event.metadata == %{}
    end

    test "emitted event is queryable from the DB", %{user: user} do
      assert {:ok, event} =
               Billing.emit(user.id, "sandbox_terminated", nil, nil, %{"duration_ms" => 30_000})

      persisted = Repo.get!(UsageEvent, event.id)
      assert persisted.user_id == user.id
      assert persisted.event_type == "sandbox_terminated"
      assert persisted.metadata == %{"duration_ms" => 30_000}
    end

    test "raises Ecto.ConstraintError when user_id does not exist (FK constraint)" do
      nonexistent_user_id = Ecto.UUID.generate()

      assert_raise Ecto.ConstraintError, ~r/usage_events_user_id_fkey/, fn ->
        Billing.emit(nonexistent_user_id, "sandbox_provisioned", nil, nil)
      end
    end
  end

  describe "create_stripe_customer/1" do
    test "on Stripe success: stores stripe_customer_id on the user" do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _attrs ->
        {:ok, %Stripe.Customer{id: "cus_new123"}}
      end)

      assert {:ok, updated_user} = Billing.create_stripe_customer(user)
      assert updated_user.stripe_customer_id == "cus_new123"
    end

    test "on Stripe error: returns {:error, reason} without modifying the user" do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _attrs ->
        {:error, %Stripe.Error{message: "card declined", source: :stripe, code: :card_declined}}
      end)

      assert {:error, %Stripe.Error{}} = Billing.create_stripe_customer(user)

      unchanged = Repo.get!(Fountain.Accounts.User, user.id)
      assert unchanged.stripe_customer_id == nil
    end
  end

  describe "usage_summary/3 — sandbox_minutes per provider" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "splits the minutes by the provider that ran them", %{user: user} do
      terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:10:00Z])
      terminated_sandbox(user, "e2b", ~U[2026-05-11 12:00:00Z], ~U[2026-05-11 12:05:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes_by_provider == %{"sprites" => 10.0, "e2b" => 5.0}
    end

    test "the split adds up to the total", %{user: user} do
      terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:10:00Z])
      terminated_sandbox(user, "daytona", ~U[2026-05-11 12:00:00Z], ~U[2026-05-11 12:07:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 17.0

      assert summary.sandbox_minutes_by_provider |> Map.values() |> Enum.sum() ==
               summary.sandbox_minutes
    end

    test "is empty for a tenant with no sandbox time", %{user: user} do
      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 0.0
      assert summary.sandbox_minutes_by_provider == %{}
    end

    test "counts a sandbox still running at the period's end", %{user: user} do
      # The gap terminate-only accrual left: a long-lived agent reported zero
      # for months and then a spike in whichever month it happened to die.
      insert_sandbox(
        user_id: user.id,
        provider: "sprites",
        status: "ready",
        inserted_at: ~U[2026-05-31 23:00:00Z]
      )

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 60.0
    end

    test "excludes parked time", %{user: user} do
      sandbox =
        terminated_sandbox(user, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, sandbox.id)
      insert_event(user, "sandbox_resumed", ~U[2026-05-10 12:50:00Z], %{}, sandbox.id)

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 30.0
    end
  end

  describe "comp_account/2 and revoke_comp/2" do
    test "comps an account: the balance is never checked, and nothing is cancelled upstream" do
      user = insert_verified_user()
      refute user.comped

      assert {:ok, updated} = Billing.comp_account(user)
      assert updated.comped
      assert Billing.check_spend(updated) == :ok
      assert {:ok, ^updated} = Billing.comp_account(updated)

      [event] =
        Fountain.Audit.list_recent_for_user(user.id, 20)
        |> Enum.filter(&(&1.action == "billing.comp.granted"))

      assert event.metadata == %{"from" => false, "to" => true}
    end

    test "revoke_comp checks the balance again, and refuses an account that was not comped" do
      user = insert_verified_user()
      {:ok, comped} = Billing.comp_account(user)

      assert {:ok, updated} = Billing.revoke_comp(comped)
      refute updated.comped
      assert {:error, :insufficient_credits} = Billing.check_spend(updated)
      assert {:error, :not_comped} = Billing.revoke_comp(updated)
    end
  end

  describe "usage_summaries/2" do
    test "aggregates per user in the window, absent users omitted" do
      a = insert_verified_user()
      b = insert_verified_user()
      quiet = insert_verified_user()

      c = Ecto.UUID.generate()
      {:ok, _} = Billing.record_usage(a.id, "sandbox_provisioned", nil, nil)
      {:ok, _} = Billing.record_usage(a.id, "turn_started", nil, nil, %{"conversation_id" => c})
      {:ok, _} = Billing.record_usage(a.id, "turn_started", nil, nil, %{"conversation_id" => c})
      {:ok, _} = Billing.record_usage(b.id, "turn_started", nil, nil, %{"conversation_id" => c})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      terminated_sandbox(a, "sprites", DateTime.add(now, -2, :minute), now)

      summaries = Billing.usage_summaries(DateTime.add(now, -1, :day), DateTime.add(now, 1, :day))

      assert summaries[a.id] == %{
               conversations: 1,
               turns: 2,
               sandbox_minutes: 2.0,
               sandbox_minutes_by_provider: %{"sprites" => 2.0},
               # No turns overlapped the sandbox, so no allowance was spent —
               # two minutes of cost against zero hours of work.
               turn_hours: 0.0
             }

      assert summaries[b.id] == %{
               conversations: 1,
               turns: 1,
               sandbox_minutes: 0.0,
               sandbox_minutes_by_provider: %{},
               turn_hours: 0.0
             }

      refute Map.has_key?(summaries, quiet.id)
    end

    test "a conversation is one that ran a turn; provisions, failed or not, are not counted" do
      a = insert_verified_user()
      c = Ecto.UUID.generate()

      {:ok, _} = Billing.record_usage(a.id, "sandbox_provisioned", nil, nil)
      {:ok, _} = Billing.record_usage(a.id, "sandbox_provision_failed", nil, nil)
      {:ok, _} = Billing.record_usage(a.id, "turn_started", nil, nil, %{"conversation_id" => c})
      {:ok, _} = Billing.record_usage(a.id, "turn_started", nil, nil, %{"conversation_id" => c})

      now = DateTime.utc_now()
      summaries = Billing.usage_summaries(DateTime.add(now, -1, :day), DateTime.add(now, 1, :day))

      assert summaries[a.id].conversations == 1
      assert summaries[a.id].turns == 2
    end

    test "subtracts parked time per sandbox, per user (#665)" do
      a = insert_verified_user()
      b = insert_verified_user()

      # a: alive an hour, parked 30 of those minutes -> nets 30.
      sandbox_a =
        terminated_sandbox(a, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      insert_event(a, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, sandbox_a.id)
      insert_event(a, "sandbox_resumed", ~U[2026-05-10 12:50:00Z], %{}, sandbox_a.id)

      # b: alive an hour, never suspended -> nets the full 60.
      terminated_sandbox(b, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 13:00:00Z])

      summaries =
        Billing.usage_summaries(~U[2026-05-01 00:00:00Z], ~U[2026-06-01 00:00:00Z])

      assert summaries[a.id].sandbox_minutes == 30.0
      assert summaries[b.id].sandbox_minutes == 60.0
    end

    test "splits each user's minutes by provider" do
      a = insert_verified_user()

      terminated_sandbox(a, "sprites", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:10:00Z])
      terminated_sandbox(a, "runner", ~U[2026-05-10 12:00:00Z], ~U[2026-05-10 12:04:00Z])

      summaries = Billing.usage_summaries(~U[2026-05-01 00:00:00Z], ~U[2026-06-01 00:00:00Z])

      assert summaries[a.id].sandbox_minutes_by_provider == %{
               "sprites" => 10.0,
               "runner" => 4.0
             }
    end
  end

  defp insert_event(user, event_type, inserted_at, metadata \\ %{}, resource_id \\ nil) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      user_id: user.id,
      event_type: event_type,
      inserted_at: inserted_at,
      metadata: metadata,
      resource_id: resource_id
    })
    |> Repo.insert!()
  end

  # Sandbox minutes are read off the sandbox rows themselves, so anything
  # asserting on them has to create one rather than hand-write an event.
  defp terminated_sandbox(user, provider, started, ended) do
    insert_sandbox(
      user_id: user.id,
      provider: provider,
      status: "terminated",
      inserted_at: started,
      terminated_at: ended
    )
  end
end
