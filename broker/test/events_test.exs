defmodule RemoteBroker.EventsTest do
  use ExUnit.Case, async: false
  alias RemoteBroker.Events

  test "terminal delivery strips sensitive data and distinguishes passthrough" do
    test = self()
    Application.put_env(:remote_broker, :control_url, "https://home.example")
    Application.put_env(:remote_broker, :token, String.duplicate("x", 48))

    Application.put_env(:remote_broker, :request_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:batch, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      end
    )

    pid = start_supervised!(Events)

    meta = %{
      meta: %{"receipt" => "signed"},
      method: "GET",
      host: "example.com",
      path: "/secret",
      error: "secret-error",
      outcome: :injected,
      scheme: :passthrough,
      rule: "ALLOW",
      status: 200
    }

    Events.record(nil, %{duration: 1_000}, meta, nil)
    send(pid, :flush)
    assert_receive {:batch, %{"events" => [event]}}
    assert event["outcome"] == "passthrough"
    assert event["service"] == nil
    refute Jason.encode!(event) =~ "secret"
  end

  test "a blocked delivery cannot grow the queue beyond 5000 events" do
    pid = start_supervised!(Events)
    :sys.suspend(pid)
    on_exit(fn -> if Process.alive?(pid), do: :sys.resume(pid) end)

    meta = %{
      meta: %{"receipt" => "signed"},
      method: "GET",
      host: "example.com",
      outcome: :passthrough,
      status: 200
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..5_010, do: Events.record(nil, %{duration: 1_000}, meta, nil)
      end)

    assert :ets.lookup_element(Events, :size, 2) == 5_000
    assert :ets.info(Events, :size) == 5_001
    assert log =~ "dropped=1"
    :sys.resume(pid)
  end
end
