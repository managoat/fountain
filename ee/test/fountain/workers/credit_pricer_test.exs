defmodule Fountain.Workers.CreditPricerTest do
  @moduledoc """
  The pricer writes one burn per closed turn, once, only on
  providers Fountain pays for, only from the configured instant.
  """

  # Message pricing changes global :credits configuration read by other suites.
  use Fountain.DataCase, async: false

  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Workers.CreditPricer

  @since ~U[2026-08-01 00:00:00Z]
  @now ~U[2026-08-03 12:00:00Z]

  defp closed_turn(conv, started, seconds) do
    insert_turn(conv, %{
      status: "completed",
      started_at: started,
      ended_at: DateTime.add(started, seconds, :second)
    })
  end

  defp setup_conv(user, provider \\ "sprites") do
    sandbox = insert_sandbox(user_id: user.id, provider: provider, status: "ready")
    insert_conversation(user_id: user.id, sandbox: sandbox)
  end

  test "a closed hour on sprites burns 25 cents, once, with the turn as the resource" do
    user = insert_empty_user()
    conv = setup_conv(user)
    turn = closed_turn(conv, ~U[2026-08-02 10:00:00Z], 3600)

    assert %{turns: 1} = CreditPricer.run(since: @since, now: @now)
    assert Credits.balance(user.id) == -25

    [entry] = Credits.list_entries(user.id)
    assert entry.reason == "burn_turn"
    assert entry.resource_type == "turn"
    assert entry.resource_id == turn.id
    assert entry.idempotency_key == "burn_turn:#{turn.id}"
    assert entry.metadata["turn_seconds"] == 3600
    assert entry.metadata["provider"] == "sprites"

    # Second run: nothing new.
    assert %{turns: 0} = CreditPricer.run(since: @since, now: @now)
    assert Credits.balance(user.id) == -25
  end

  test "open turns, runner turns, and turns before the floor are not priced" do
    user = insert_empty_user()
    conv = setup_conv(user)
    # Still running.
    insert_turn(conv, %{status: "running", started_at: ~U[2026-08-02 10:00:00Z]})
    # Closed before the floor.
    closed_turn(conv, ~U[2026-07-30 10:00:00Z], 7200)
    # The tenant's own machine.
    runner_conv = setup_conv(user, "runner")
    closed_turn(runner_conv, ~U[2026-08-02 11:00:00Z], 7200)

    assert %{turns: 0} = CreditPricer.run(since: @since, now: @now)
    assert Credits.balance(user.id) == 0
  end

  test "an orphaned turn is not priced" do
    user = insert_empty_user()
    conv = setup_conv(user)

    insert_turn(conv, %{
      status: "interrupted",
      started_at: ~U[2026-08-02 10:00:00Z],
      ended_at: ~U[2026-08-02 14:00:00Z],
      orphaned_at: ~U[2026-08-02 14:00:00Z]
    })

    assert %{turns: 0} = CreditPricer.run(since: @since, now: @now)
    assert Credits.list_entries(user.id) == []
  end

  test "a turn that rounds to zero cents writes nothing and is not an error" do
    user = insert_empty_user()
    conv = setup_conv(user)
    closed_turn(conv, ~U[2026-08-02 10:00:00Z], 60)

    assert %{turns: 0} = CreditPricer.run(since: @since, now: @now)
    assert Credits.list_entries(user.id) == []
  end

  test "every tick also sweeps expired grants (#1126)" do
    user = insert_empty_user()

    {:ok, _} =
      Credits.grant(user.id, 500, "grant_opening",
        idempotency_key: "g",
        expires_at: ~U[2026-08-03 00:00:00Z]
      )

    assert %{expired: 1} = CreditPricer.run(since: @since, now: @now)
    assert Credits.balance(user.id) == 0
    assert %{expired: 0} = CreditPricer.run(since: @since, now: @now)
  end

  test "a comped tenant's turns are still written to the ledger" do
    user = insert_empty_user()
    {:ok, user} = Billing.comp_account(user)
    conv = setup_conv(user)
    closed_turn(conv, ~U[2026-08-02 10:00:00Z], 3600)

    assert %{turns: 1} = CreditPricer.run(since: @since, now: @now)
    assert Credits.balance(user.id) == -25
    assert :ok = Credits.check_balance(user.id)
  end

  test "the look-back never reaches further than seven days before now" do
    user = insert_empty_user()
    conv = setup_conv(user)
    closed_turn(conv, ~U[2026-07-20 10:00:00Z], 3600)
    closed_turn(conv, ~U[2026-08-02 10:00:00Z], 3600)

    assert %{turns: 1} = CreditPricer.run(since: ~U[2026-01-01 00:00:00Z], now: @now)
  end

  test "perform/1 prices a turn closed within the last seven days — no option needed" do
    user = insert_empty_user()
    conv = setup_conv(user)

    closed_turn(
      conv,
      DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second),
      3600
    )

    assert :ok = CreditPricer.perform(%Oban.Job{args: %{}})
    assert Credits.balance(user.id) == -25
  end
end

# Billing off is a global switch (`:credits_enabled` in the application env),
# so a test that flips it cannot share a scheduler with tests that read it.
# ExUnit runs `async: false` modules alone, after the async ones, which is the
# isolation this needs. Left async, this test turned a concurrent credits
# assertion red on the wrong seed.

defmodule Fountain.Workers.CreditPricerBillingOffTest do
  use Fountain.DataCase, async: false

  alias Fountain.Credits
  alias Fountain.Workers.CreditPricer

  test "no-ops with billing off" do
    user = insert_empty_user()
    sandbox = insert_sandbox(user_id: user.id, provider: "sprites", status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox)

    insert_turn(conv, %{
      status: "completed",
      started_at: ~U[2026-08-02 10:00:00Z],
      ended_at: ~U[2026-08-02 11:00:00Z]
    })

    Application.put_env(:fountain, :credits_enabled, false)
    on_exit(fn -> Application.put_env(:fountain, :credits_enabled, true) end)

    assert %{turns: 0} =
             CreditPricer.run(since: ~U[2026-08-01 00:00:00Z], now: ~U[2026-08-03 12:00:00Z])

    assert Credits.balance(user.id) == 0
  end
end
