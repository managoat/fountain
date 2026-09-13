defmodule Fountain.Workers.BrokerReaperTest do
  # The daily sweep of what the egress broker leaves behind (#1487): expired
  # sessions, and egress rows past BROKER_LOG_RETENTION_HOURS. Global app env,
  # so async: false.
  use Fountain.DataCase, async: false

  alias Fountain.Broker
  alias Fountain.Broker.Native.Request
  alias Fountain.Broker.Native.RequestLog
  alias Fountain.Broker.Native.Session
  alias Fountain.Workers.BrokerReaper

  @keys [:broker_listen_port, :broker_proxy_url, :broker_log_retention_hours]

  setup do
    previous = for k <- @keys, do: {k, Application.get_env(:fountain, k)}

    on_exit(fn ->
      for {k, v} <- previous do
        if is_nil(v),
          do: Application.delete_env(:fountain, k),
          else: Application.put_env(:fountain, k, v)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 0)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    # One writer per test: `use GenServer` gives every child spec the module's
    # own id, so a second start_supervised! of it in one test collides.
    pid =
      start_supervised!({RequestLog, name: :"reaper_log_#{System.unique_integer([:positive])}"})

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    {:ok, user: user, conv: conv, log: pid}
  end

  defp write_request(%{conv: conv, user: user, log: pid}, at) do
    RequestLog.record(
      %{
        conversation_id: conv.id,
        user_id: user.id,
        method: "GET",
        host: "api.github.com",
        path: "/user",
        outcome: "passthrough",
        service: nil,
        credential_keys: [],
        inserted_at: at
      },
      pid
    )

    :ok = RequestLog.flush(pid)
  end

  test "a no-op with the broker off" do
    Application.delete_env(:fountain, :broker_listen_port)
    assert %{sessions: 0, requests: 0} = BrokerReaper.run()
  end

  test "sweeps a session past its end and leaves a live one", %{user: user, conv: conv} do
    {:ok, _} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
    assert Repo.aggregate(Session, :count, :id) == 1

    # Live: the sweep must not take it.
    assert %{sessions: 0} = BrokerReaper.run()
    assert Repo.aggregate(Session, :count, :id) == 1

    Repo.update_all(Session, set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)])

    assert %{sessions: 1} = BrokerReaper.run()
    assert Repo.aggregate(Session, :count, :id) == 0
  end

  test "sweeps egress rows past the retention and leaves the rest", ctx do
    Application.put_env(:fountain, :broker_log_retention_hours, 168)

    write_request(ctx, DateTime.add(DateTime.utc_now(), -8 * 24 * 3600, :second))
    write_request(ctx, DateTime.utc_now())
    assert Repo.aggregate(Request, :count, :id) == 2

    assert %{requests: 1} = BrokerReaper.run()
    assert Repo.aggregate(Request, :count, :id) == 1
  end

  test "the retention hours are what decides", ctx do
    Application.put_env(:fountain, :broker_log_retention_hours, 1)
    write_request(ctx, DateTime.add(DateTime.utc_now(), -2 * 3600, :second))

    assert %{requests: 1} = BrokerReaper.run()
    assert Repo.aggregate(Request, :count, :id) == 0
  end

  test "`now:` pins the clock", ctx do
    Application.put_env(:fountain, :broker_log_retention_hours, 168)
    write_request(ctx, DateTime.utc_now())

    # A row written now is old relative to a clock set far enough ahead.
    future = DateTime.add(DateTime.utc_now(), 9 * 24 * 3600, :second)
    assert %{requests: 1} = BrokerReaper.run(now: future)
  end

  test "perform/1 runs the sweep", ctx do
    write_request(ctx, DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second))
    assert :ok = perform_job(BrokerReaper, %{})
    assert Repo.aggregate(Request, :count, :id) == 0
  end
end
