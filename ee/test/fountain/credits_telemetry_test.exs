defmodule Fountain.CreditsTelemetryTest do
  @moduledoc """
  What the credit machinery reports about itself (#1169).

  Two questions, and the whole point is that they are separate: a worker can
  run on schedule and still move no money, which is the failure the old
  coverage (`FountainObanJobsRaising`, which needs a *raise*) could not see.

  `async: false`, and it genuinely needs to be: a `:telemetry` handler is
  **global**, so an async module receives the events of every other module
  running beside it. `[:fountain, :credits, :posted]` fires on any ledger
  write anywhere — including the $5 opening grant that `insert_verified_user/0`
  posts — so `refute_receive` here caught another module's grant and failed
  under the full suite while passing when run alone.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Credits
  alias Fountain.Credits.Telemetry

  defp attach(event) do
    test = self()
    handler = "t-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      event,
      fn _e, measurements, meta, _cfg -> send(test, {:telemetry, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "[:fountain, :credits, :posted]" do
    # The users are made BEFORE the handler attaches. Verification posts the
    # $5 opening grant, which is itself a ledger write and so reports too —
    # true to the design, and noise for a test that asserts nothing else
    # arrives.
    setup do
      user = insert_verified_user()
      empty = insert_empty_user()
      attach([:fountain, :credits, :posted])
      %{user: user, empty: empty}
    end

    test "a debit reports its cents and reason", %{user: user} do
      {:ok, _} = Credits.debit(user.id, 137, "burn_turn", idempotency_key: "t1")

      assert_receive {:telemetry, %{cents: 137}, %{reason: "burn_turn", direction: "debit"}}
    end

    test "a grant reports as a credit", %{empty: empty} do
      {:ok, _} = Credits.grant(empty.id, 500, "grant_admin", idempotency_key: "g1")

      assert_receive {:telemetry, %{cents: 500}, %{reason: "grant_admin", direction: "credit"}}
    end

    # The seven-day look-back re-reads rows that already exist, so a pricer
    # pass over old turns writes nothing. If a duplicate measured anyway,
    # "cents burned today" would read healthy while the pricer priced nothing
    # new — exactly the signal this exists to give.
    test "a duplicate post measures nothing", %{user: user} do
      {:ok, _} = Credits.debit(user.id, 10, "burn_turn", idempotency_key: "dup")
      assert_receive {:telemetry, %{cents: 10}, _}

      Credits.debit(user.id, 10, "burn_turn", idempotency_key: "dup")
      refute_receive {:telemetry, %{cents: 10}, %{reason: "burn_turn"}}, 100
    end

    test "a rejected post measures nothing", %{user: user} do
      # Zero is not a valid ledger row, so the changeset never reaches the
      # database and nothing should be reported as moved.
      Credits.post(user.id, 0, "burn_turn", idempotency_key: "zero")

      refute_receive {:telemetry, _, %{reason: "burn_turn"}}, 100
    end
  end

  describe "[:fountain, :credits, :worker, :run]" do
    setup do
      attach([:fountain, :credits, :worker, :run])
      :ok
    end

    test "reports a wall-clock stamp and the rows written" do
      before = System.system_time(:second)

      Telemetry.emit_run("pricer", %{turns: 3, inference: 1, messages: 0, expired: 2})

      assert_receive {:telemetry, measurements, %{worker: "pricer"}}
      assert measurements.total == 6
      assert measurements.turns == 3
      assert measurements.last_run_unix >= before
    end

    # The staleness alert is the reason this is a stamp rather than a counter:
    # a pass that did nothing must still say it happened, or "the pricer has
    # not run" and "the pricer found no work" look identical.
    test "a pass that wrote nothing still reports that it ran" do
      Telemetry.emit_run("expirer", %{expired: 0})

      assert_receive {:telemetry, %{total: 0, last_run_unix: stamp}, %{worker: "expirer"}}
      assert is_integer(stamp)
    end

    test "each worker is its own series" do
      Telemetry.emit_run("pricer", %{turns: 1, inference: 0, expired: 0})

      assert_receive {:telemetry, %{total: 1}, %{worker: "pricer"}}
    end
  end
end
