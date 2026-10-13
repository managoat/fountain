defmodule Fountain.OpsGaugesTest do
  # #321: conversation/sandbox count gauges and Oban queue metrics. The
  # poller is off in test (gauge_poller_enabled: false), so these call
  # emit_telemetry/0 directly — the same function the poller invokes.
  use Fountain.DataCase, async: false

  alias Fountain.OpsGauges

  defp attach(events) do
    ref = make_ref()
    test = self()

    for event <- events do
      :telemetry.attach(
        {ref, event},
        event,
        fn ev, measurements, meta, _ -> send(test, {:telemetry, ev, measurements, meta}) end,
        nil
      )
    end

    on_exit(fn ->
      for event <- events, do: :telemetry.detach({ref, event})
    end)
  end

  test "emits a datapoint for every known status, zeros included" do
    attach([[:fountain, :conversations], [:fountain, :sandboxes], [:fountain, :oban_queue]])

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    insert_conversation(user_id: user.id, agent_id: agent.id, status: "idle")

    assert :ok = OpsGauges.emit_telemetry()

    # One series per conversation status — the zero series must exist too,
    # or alerts can't see recovery and panels only appear mid-incident.
    for status <- Fountain.Conversations.Conversation.statuses() do
      expected = if status == "idle", do: 1, else: 0

      assert_receive {:telemetry, [:fountain, :conversations], %{count: ^expected},
                      %{status: ^status}}
    end

    for status <- Fountain.Conversations.Sandbox.statuses() do
      assert_receive {:telemetry, [:fountain, :sandboxes], %{count: _}, %{status: ^status}}
    end

    # Every configured queue × watched state, zeros included.
    for queue <- ~w(maintenance mailer),
        state <- ~w(available scheduled executing retryable discarded) do
      assert_receive {:telemetry, [:fountain, :oban_queue], %{depth: _},
                      %{queue: ^queue, state: ^state}}
    end
  end

  test "counts non-terminal sandboxes by provider and status" do
    # The live counterpart to the after-the-fact roll-up: which providers are
    # charging us right now. Tagged by provider, never by tenant — that would
    # be one Prometheus series per account.
    attach([[:fountain, :sandboxes_by_provider]])

    user = insert_verified_user()
    insert_sandbox(user_id: user.id, provider: "e2b", status: "ready")
    insert_sandbox(user_id: user.id, provider: "e2b", status: "ready")
    insert_sandbox(user_id: user.id, provider: "sprites", status: "suspended")

    assert :ok = OpsGauges.emit_telemetry()

    assert_receive {:telemetry, [:fountain, :sandboxes_by_provider], %{count: 2},
                    %{provider: "e2b", status: "ready"}}

    assert_receive {:telemetry, [:fountain, :sandboxes_by_provider], %{count: 1},
                    %{provider: "sprites", status: "suspended"}}

    # Zeros for every provider Fountain knows, so a series exists from boot.
    for provider <- Fountain.SandboxProviders.known_providers() do
      assert_receive {:telemetry, [:fountain, :sandboxes_by_provider], %{count: _},
                      %{provider: ^provider, status: "pending"}}
    end
  end

  test "does not count terminal sandboxes — those rows are history, not a signal" do
    attach([[:fountain, :sandboxes_by_provider]])

    user = insert_verified_user()
    insert_sandbox(user_id: user.id, provider: "e2b", status: "terminated")

    assert :ok = OpsGauges.emit_telemetry()

    refute_receive {:telemetry, [:fountain, :sandboxes_by_provider], _,
                    %{provider: "e2b", status: "terminated"}}
  end

  test "counts queued Oban jobs by queue and state" do
    attach([[:fountain, :oban_queue]])

    Repo.insert!(%Oban.Job{queue: "maintenance", worker: "Test.Worker", state: "available"})
    Repo.insert!(%Oban.Job{queue: "maintenance", worker: "Test.Worker", state: "available"})
    Repo.insert!(%Oban.Job{queue: "mailer", worker: "Test.Worker", state: "discarded"})

    assert :ok = OpsGauges.emit_telemetry()

    assert_receive {:telemetry, [:fountain, :oban_queue], %{depth: 2},
                    %{queue: "maintenance", state: "available"}}

    assert_receive {:telemetry, [:fountain, :oban_queue], %{depth: 1},
                    %{queue: "mailer", state: "discarded"}}
  end

  test "a raising tick is skipped, not propagated — the poller trap (#365)" do
    import ExUnit.CaptureLog

    # Corrupt the Oban config so the tick raises mid-function — the shape of
    # any transient failure. It must rescue: telemetry_poller permanently
    # drops a measurement whose tick raises.
    previous = Application.fetch_env!(:fountain, Oban)
    Application.put_env(:fountain, Oban, :corrupt)
    on_exit(fn -> Application.put_env(:fountain, Oban, previous) end)

    log = capture_log(fn -> assert :ok = OpsGauges.emit_telemetry() end)
    assert log =~ "ops gauges tick skipped"
  end
end
