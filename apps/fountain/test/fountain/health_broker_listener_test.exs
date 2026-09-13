defmodule Fountain.HealthBrokerListenerTest do
  @moduledoc """
  The broker-listener check behind the readiness probe, end to end: the real
  `Fountain.Health`, a real listener, and the real endpoint.

  `async: false` because the check is selected by `:broker_listen_port`, which
  is application environment — global state an async test writing it would
  leak into whatever else was running (#1214 is the flake that taught this
  repo the lesson). `Fountain.BrokerTestHelpers.enable_broker/0` is the
  established way to set those keys and put them back afterwards.

  The listener binds port 0 rather than the helper's fixed port, so two
  checkouts running their suites at once cannot fight over a socket. Nothing
  here dials the proxy; it only asks whether one is up.
  """

  use FountainWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Broker
  alias Fountain.Broker.Native
  alias Fountain.Health

  describe "broker_listener/0" do
    test "is :ok when no listen port is configured" do
      # Brokerage off is the default here, which is also why the rest of the
      # suite is untouched by this check existing.
      refute Broker.configured?()

      assert Health.broker_listener() == :ok
    end

    test "is :error when a port is configured and nothing is accepting" do
      configure_broker()

      log = capture_log(fn -> assert Health.broker_listener() == :error end)

      assert log =~ "readiness: broker listener check failed"
    end

    test "is :ok when the listener is up" do
      configure_broker()
      start_supervised!(Native.listener_spec())

      assert Health.broker_listener() == :ok
    end

    test "the failure reason never leaves the module" do
      # Same contract as database/1: the probe is public, so the check answers
      # a bare atom and the detail goes to the log instead.
      configure_broker()

      {result, log} = with_log(fn -> Health.broker_listener() end)

      assert result == :error
      assert log =~ "listener_down"
    end
  end

  describe "GET /health/ready" do
    test "is 200 when no listen port is configured", %{conn: conn} do
      body = conn |> get("/health/ready") |> json_response(200)

      assert body["checks"]["broker_listener"] == "ok"
    end

    test "is 503 when a port is configured and the listener is down", %{conn: conn} do
      # The #1726 window: the listener is a supervised child started after
      # FountainWeb.Endpoint, so a fresh pod serves HTTP with nothing bound.
      # Before this check the pod answered 200 here and took provisions it
      # could only fail with :listener_down.
      configure_broker()

      {conn, _log} = with_log(fn -> get(conn, "/health/ready") end)

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["status"] == "error"
      assert body["checks"]["broker_listener"] == "error"
      assert body["checks"]["database"] == "ok"
    end

    test "says no more about the failure than which check failed", %{conn: conn} do
      configure_broker()

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
      configure_broker()
      start_supervised!(Native.listener_spec())

      body = conn |> get("/health/ready") |> json_response(200)

      assert body["status"] == "ok"
      assert body["checks"]["broker_listener"] == "ok"
    end

    test "liveness keeps answering while the listener is down", %{conn: conn} do
      # A late listener must pull the pod from the Service, never restart it —
      # a restart would only start the same race again.
      configure_broker()

      assert conn |> get("/health") |> json_response(200)

      {ready, _log} = with_log(fn -> get(conn, "/health/ready") end)
      assert json_response(ready, 503)
    end
  end

  defp configure_broker do
    Fountain.BrokerTestHelpers.enable_broker()
    # Port 0: the OS picks a free one. `Fountain.Broker.backend/0` asks only
    # whether the value is an integer.
    Application.put_env(:fountain, :broker_listen_port, 0)
    :ok
  end
end
