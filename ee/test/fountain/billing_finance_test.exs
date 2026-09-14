defmodule Fountain.Billing.FinanceTest do
  @moduledoc """
  The finance panel's numbers: credit revenue, cost per tenant, and the
  margin between them.

  Three properties carry the page, and each is tested against the way it would
  otherwise lie:

    * **`nil` is not zero.** An unpriced line has to stay unpriced all the way
      to the total. A cost that silently drops the part nobody gave a rate for
      reads as a cheap tenant.
    * **Revenue is credit burned (ADR 0031).** Sold credit is cash and a
      liability until burned; a comped account's burn is never revenue.
    * **The cost basis changes the price and never the hours.** Which hours a
      provider bills is a fact about their invoice, so the panel offers both;
      a toggle whose arithmetic did not differ would be decoration.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Conversations

  # Wholly in the past, so the attribution ceiling is the period end and every
  # figure below is exact rather than a function of the wall clock.
  @period_start ~U[2026-05-01 00:00:00Z]
  @period_end ~U[2026-06-01 00:00:00Z]
  @period {@period_start, @period_end}
  # After the period, so `period_fraction/3` is a full month.
  @now ~U[2026-06-02 00:00:00Z]

  setup do
    # async: false and an explicit reset: the rate card is application env,
    # which is global. Every test states the card it wants.
    original =
      Map.new(
        [
          :provider_hourly_cents,
          :cost_basis
        ],
        &{&1, Application.get_env(:fountain, &1)}
      )

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    Enum.each(original, fn {key, _} -> Application.delete_env(:fountain, key) end)
    :ok
  end

  defp rate_card(opts) do
    Enum.each(opts, fn {key, value} -> Application.put_env(:fountain, key, value) end)
  end

  defp subscriber(_plan, _status \\ "active"), do: insert_empty_user()

  # A sandbox that ran for `hours`, with a prompt in flight for `busy_hours` of
  # them. The rest is idle: real cost, no allowance spent.
  defp ran(user, provider, hours, busy_hours) do
    started = @period_start
    ended = DateTime.add(started, hours * 3600, :second)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        provider: provider,
        status: "terminated",
        inserted_at: started,
        terminated_at: ended
      )

    if busy_hours > 0 do
      agent = insert_agent(user_id: user.id)

      conversation =
        insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      {:ok, _} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conversation.id,
          turn_number: System.unique_integer([:positive]),
          prompt: "hello",
          status: "completed",
          started_at: started,
          ended_at: DateTime.add(started, busy_hours * 3600, :second)
        })
    end

    sandbox
  end

  defp summary, do: Finance.summary(period: @period, now: @now)

  defp row_for(summary, user), do: Enum.find(summary.tenants, &(&1.user_id == user.id))

  ## ── the rate card ─────────────────────────────────────────────────────────

  describe "rate_card/0 and priced?/0" do
    test "a deployment that has set nothing prices nothing" do
      refute Finance.priced?()

      assert %{providers: %{}} = Finance.rate_card()
    end

    test "one rate is enough to be priced" do
      rate_card(provider_hourly_cents: %{"sprites" => 200})
      assert Finance.priced?()
    end

    test "a fractional rate survives" do
      rate_card(provider_hourly_cents: %{"sprites" => 10.76})

      assert %{providers: %{"sprites" => 10.76}} = Finance.rate_card()
      assert Finance.priced?()
    end

    test "the default basis is active, and only an exact \"turn\" changes it" do
      assert Finance.default_basis() == :active

      Application.put_env(:fountain, :cost_basis, :turn)
      assert Finance.default_basis() == :turn

      # A typo must not quietly halve the reported bill.
      Application.put_env(:fountain, :cost_basis, "Turn")
      assert Finance.default_basis() == :active

      Application.delete_env(:fountain, :cost_basis)
    end
  end

  ## ── cost, and the nil that must not become a zero ─────────────────────────

  describe "cost" do
    test "sandbox cost is active hours at the provider's rate, idle included" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      row = row_for(summary(), user)

      # Ten hours awake, two of them working. The provider charges for ten.
      assert row.active_hours == 10.0
      assert row.turn_hours == 2.0
      assert row.idle_hours == 8.0
      assert row.sandbox_cost_cents == 1000
    end

    test "the turn basis charges only the hours with a prompt in flight" do
      # Which of the two a provider actually bills is a fact about their
      # invoice. The panel offers both so the totals can be compared against
      # one; the arithmetic has to differ, or the toggle is decoration.
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      active = Finance.summary(period: @period, now: @now, basis: :active) |> row_for(user)
      turn = Finance.summary(period: @period, now: @now, basis: :turn) |> row_for(user)

      assert active.sandbox_cost_cents == 1000
      assert turn.sandbox_cost_cents == 200

      # Both rows still report both hour figures whichever basis priced them.
      assert turn.active_hours == 10.0
      assert turn.turn_hours == 2.0
    end

    test "the turn basis reports no idle saving, because idle is already free" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      assert Finance.summary(period: @period, now: @now, basis: :active).cost.idle_cents == 800
      # Nothing for a shorter timeout to remove — claiming a saving here would
      # be an invention.
      assert Finance.summary(period: @period, now: @now, basis: :turn).cost.idle_cents == nil
    end

    test "the basis reaches the totals and says which one it was" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      turn = Finance.summary(period: @period, now: @now, basis: :turn)

      assert turn.cost.basis == :turn
      assert turn.rate_card.basis == :turn
      assert turn.cost.sandbox_cents == 200
      # The hours themselves never change with the basis; only the price does.
      assert turn.cost.active_hours == 10.0
    end

    test "an unattributable sandbox is priced on the same basis as the rest" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)
      Repo.update_all(Fountain.Conversations.Sandbox, set: [user_id: nil])

      assert Finance.summary(period: @period, now: @now, basis: :active).unattributed_cost_cents ==
               1000

      assert Finance.summary(period: @period, now: @now, basis: :turn).unattributed_cost_cents ==
               200
    end

    test "a provider with no rate leaves the tenant's cost nil, not short" do
      # The failure this guards: pricing sprites, saying nothing about e2b, and
      # reporting a cost that quietly covers only half the hours.
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 10)
      ran(user, "e2b", 10, 10)

      row = row_for(summary(), user)

      assert row.active_hours == 20.0
      assert row.sandbox_cost_cents == nil
      assert row.cost_cents == nil
      assert row.margin_cents == nil
    end

    test "a tenant's own runner costs nothing, and needs no rate to say so" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 1, 1)
      ran(user, "runner", 100, 100)

      row = row_for(summary(), user)

      # The runner hours are real and reported...
      assert row.active_hours == 101.0
      # ...and priced at zero rather than dropping the whole row to nil:
      # ADR 0022 says Fountain pays nothing for that machine.
      assert row.sandbox_cost_cents == 100
    end

    test "runner turn hours do not count against the plan" do
      user = subscriber("solo")
      ran(user, "runner", 50, 50)

      row = row_for(summary(), user)

      assert row.active_hours == 50.0
      assert row.turn_hours == 0.0
    end

    test "a fractional provider rate prices the hours it should" do
      rate_card(provider_hourly_cents: %{"sprites" => 10.76})
      user = subscriber("solo")
      ran(user, "sprites", 100, 100)

      # 100 hours at 10.76c, whichever basis — they are equal here.
      assert row_for(summary(), user).sandbox_cost_cents == 1076
    end
  end

  ## ── revenue ──────────────────────────────────────────────────────────────

  describe "revenue" do
    test "earned is credit burned by paying accounts; sold is packs; comped burn is neither" do
      paying = subscriber("solo")
      comped = subscriber("solo")
      {:ok, _} = Billing.comp_account(comped)
      at = DateTime.add(@period_start, 3600, :second)

      {:ok, _} = Fountain.Credits.grant(paying.id, 2500, "purchase", idempotency_key: "p")
      {:ok, _} = Fountain.Credits.debit(paying.id, 700, "burn_turn", idempotency_key: "b1")
      {:ok, _} = Fountain.Credits.debit(comped.id, 300, "burn_turn", idempotency_key: "b2")
      Repo.update_all(Fountain.Credits.LedgerEntry, set: [inserted_at: at])

      revenue = summary().revenue
      assert revenue.sold_cents == 2500
      assert revenue.earned_cents == 700
      assert revenue.comped_cents == 300

      assert row_for(summary(), paying).revenue_cents == 700
      assert row_for(summary(), comped).revenue_cents == 0
      assert row_for(summary(), comped).comped
    end
  end

  ## ── margin ───────────────────────────────────────────────────────────────

  describe "margin" do
    test "a tenant costing more than they pay shows negative, and sorts first" do
      rate_card(provider_hourly_cents: %{"sprites" => 500})

      cheap = subscriber("scale")
      ran(cheap, "sprites", 1, 1)

      expensive = subscriber("solo")
      ran(expensive, "sprites", 100, 100)

      summary = summary()

      # No credit burned in the ledger for this period, so revenue is zero and
      # the margin is the cost, negative.
      assert row_for(summary, expensive).margin_cents == -50_000

      assert row_for(summary, expensive).margin_cents < 0
      # One hour at $5 with nothing burned: also negative, but far less so.
      assert row_for(summary, cheap).margin_cents == -500
      assert hd(summary.tenants).user_id == expensive.id
    end

    test "with no rate card there is no margin, and rows sort by hours" do
      quiet = subscriber("solo")
      ran(quiet, "sprites", 1, 1)

      busy = subscriber("solo")
      ran(busy, "sprites", 40, 40)

      summary = summary()

      assert row_for(summary, busy).margin_cents == nil
      assert hd(summary.tenants).user_id == busy.id
    end
  end

  ## ── the totals ───────────────────────────────────────────────────────────

  describe "summary/1" do
    test "credits: granted, burned and sold over the period, deferred balance today" do
      user = subscriber("solo")
      other = subscriber("team")
      at = DateTime.add(@period_start, 3600, :second)

      {:ok, _} = Fountain.Credits.grant(user.id, 1000, "grant_opening", idempotency_key: "g1")
      {:ok, _} = Fountain.Credits.grant(user.id, 2500, "purchase", idempotency_key: "p1")
      {:ok, _} = Fountain.Credits.debit(user.id, 700, "burn_turn", idempotency_key: "b1")
      {:ok, _} = Fountain.Credits.grant(other.id, 2500, "grant_opening", idempotency_key: "g2")
      # An expiry is neither granted nor burned.
      {:ok, _} = Fountain.Credits.debit(other.id, 2500, "expire", idempotency_key: "x1")

      # The ledger stamps now; the summary is over a fixed past month, so
      # place the rows inside it.
      Repo.update_all(Fountain.Credits.LedgerEntry, set: [inserted_at: at])

      credits = summary().credits
      assert credits.granted_cents == 3500
      assert credits.burned_cents == 700
      assert credits.sold_cents == 2500
      # user holds 2800, other holds 0.
      assert credits.deferred_cents == 2800
      assert credits.negative_balances == 0
      assert credits.utilization == Float.round(700 / 6000, 4)

      row = row_for(summary(), user)
      assert row.credit_granted_cents == 1000
      assert row.credit_burned_cents == 700
      assert row.credit_sold_cents == 2500
      assert row.credit_balance_cents == 2800
      assert summary().revenue.sold_cents == 2500
    end

    test "a balance below zero is counted" do
      user = subscriber("solo")
      {:ok, _} = Fountain.Credits.debit(user.id, 5, "burn_turn", idempotency_key: "neg")
      assert summary().credits.negative_balances == 1
      assert row_for(summary(), user).credit_balance_cents == -5
    end

    test "spend by a deleted account stays in the total and out of the rows" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 10)

      # Deletion nilifies the owner rather than dropping the row (0009); the
      # platform still paid for those hours.
      Repo.update_all(Fountain.Conversations.Sandbox, set: [user_id: nil])

      summary = summary()

      assert summary.tenants |> Enum.map(& &1.active_hours) |> Enum.sum() == 0.0
      assert summary.cost.active_hours == 10.0
      assert summary.unattributed_cost_cents == 1000
    end

    test "the cost total includes providers no tenant row could carry" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 2, 2)

      summary = summary()

      assert summary.cost.sandbox_cents == 200
      assert summary.cost.active_hours == 2.0
      assert summary.cost.idle_hours == 0.0
    end

    test "period_fraction is bounded and a past period is whole" do
      assert Finance.period_fraction(@period_start, @period_end, @now) == 1.0
      assert Finance.period_fraction(@period_start, @period_end, ~U[2026-04-01 00:00:00Z]) == 0.0

      assert_in_delta Finance.period_fraction(
                        @period_start,
                        @period_end,
                        ~U[2026-05-16 12:00:00Z]
                      ),
                      0.5,
                      0.01
    end
  end

  ## ── the fold /admin shares ────────────────────────────────────────────────

  describe "usage_by_user/1" do
    test "keeps the busy/idle split by_user/1 collapses away" do
      user = subscriber("solo")
      ran(user, "sprites", 10, 3)

      rows = Fountain.Billing.SandboxUsage.attribution(@period_start, @period_end, now: @now)
      usage = Finance.usage_by_user(rows)

      assert %{active_seconds: 36_000, busy_seconds: 10_800, idle_seconds: 25_200} =
               usage[user.id]

      assert [%{provider: "sprites", active: 36_000, busy: 10_800}] = usage[user.id].by_provider
    end

    test "drops the unattributable rows a user map has no key for" do
      user = subscriber("solo")
      ran(user, "sprites", 1, 1)
      Repo.update_all(Fountain.Conversations.Sandbox, set: [user_id: nil])

      rows = Fountain.Billing.SandboxUsage.attribution(@period_start, @period_end, now: @now)

      assert Finance.usage_by_user(rows) == %{}
    end
  end

  ## ── usage_summaries, which /admin's table reads ───────────────────────────

  describe "Billing.usage_summaries/2 turn hours" do
    test "reports turn hours beside sandbox minutes" do
      user = subscriber("solo")
      ran(user, "sprites", 10, 3)

      summary = Billing.usage_summaries(@period_start, @period_end)[user.id]

      assert summary.turn_hours == 3.0
      assert summary.sandbox_minutes == 600.0
    end

    test "excludes runner hours from turn hours but not from sandbox minutes" do
      user = subscriber("solo")
      ran(user, "runner", 4, 4)

      summary = Billing.usage_summaries(@period_start, @period_end)[user.id]

      assert summary.turn_hours == 0.0
      assert summary.sandbox_minutes == 240.0
    end
  end

  ## ── helpers ──────────────────────────────────────────────────────────────
end
