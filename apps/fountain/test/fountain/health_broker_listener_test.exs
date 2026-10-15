defmodule Fountain.HealthBrokerListenerTest do
  @moduledoc """
  The broker-listener check behind the readiness probe, end to end: the real
  `Fountain.Health`, a real listener, and the real endpoint.

  `async: false` because each test takes the application's listener away
  (`Fountain.BrokerTestHelpers.own_broker/0`) to see the probe with nothing
  accepting, which is global state.
  """

  use FountainWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Fountain.BrokerTestHelpers

  alias Fountain.Broker.Native
  alias Fountain.Health

  setup do
    own_broker()
  end

  describe "broker_listener/0" do
    test "is :error when nothing is accepting" do
      log = capture_log(fn -> assert Health.broker_listener() == :error end)

      assert log =~ "readiness: broker listener check failed"
    end

    test "is :ok when the listener is up" do
      start_supervised!(Native.listener_spec())

      assert Health.broker_listener() == :ok
    end

    test "the failure reason never leaves the module" do
      # Same contract as database/1: the probe is public, so the check answers
      # a bare atom and the detail goes to the log instead.
      {result, log} = with_log(fn -> Health.broker_listener() end)

      assert result == :error
      assert log =~ "listener_down"
    end
  end

  describe "GET /health/ready" do
    test "is 503 when the listener is down", %{conn: conn} do
      # The #1726 window: the listener is a supervised child started after
      # FountainWeb.Endpoint, so a fresh pod serves HTTP with nothing bound.
      # Before this check the pod answered 200 here and took provisions it
      # could only fail with :listener_down.
      {conn, _log} = with_log(fn -> get(conn, "/health/ready") end)

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["status"] == "error"
      assert body["checks"]["broker_listener"] == "error"
      assert body["checks"]["database"] == "ok"
    end

    test "says no more about the failure than which check failed", %{conn: conn} do
      {conn, _log} = with_log(fn -> get(conn, "/health/ready") end)
      raw = conn.resp_body

      assert Jason.decode!(raw) == %{
               "status" => "error",
               "checks" => %{"database" => "ok", "broker_listener" => "error"}
             }

      for leak <- ~w(listener_down Managoat ThousandIsland port 14322) do
        refute raw =~ leak
      end
    end

    test "is 200 once the listener is up", %{conn: conn} do
      start_supervised!(Native.listener_spec())

      body = conn |> get("/health/ready") |> json_response(200)

      assert body["status"] == "ok"
      assert body["checks"]["broker_listener"] == "ok"
    end

    test "liveness keeps answering while the listener is down", %{conn: conn} do
      # A late listener must pull the pod from the Service, never restart it —
      # a restart would only start the same race again.
      assert conn |> get("/health") |> json_response(200)

      {ready, _log} = with_log(fn -> get(conn, "/health/ready") end)
      assert json_response(ready, 503)
    end
  end
end
