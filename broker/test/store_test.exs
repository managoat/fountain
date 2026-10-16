defmodule RemoteBroker.StoreTest do
  use ExUnit.Case, async: false
  alias RemoteBroker.Store
  import ExUnit.CaptureLog

  defmodule ErrorAdapter do
    def run(request), do: {request, Process.get({__MODULE__, :error})}
  end

  setup do
    for {key, value} <- [
          control_url: "https://home.example",
          token: String.duplicate("x", 48),
          request_options: [plug: {Req.Test, __MODULE__}]
        ] do
      Application.put_env(:remote_broker, key, value)
    end

    :ok
  end

  test "lookup carries no credentials and always enables per-request authorization" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/internal/broker/v1/lookup"

      Req.Test.json(conn, %{
        authorization: "session-id",
        expires_at: "2099-01-01T00:00:00Z",
        policy: "deny",
        patterns: ["api.example.com"],
        receipt: "signed-receipt"
      })
    end)

    assert {:ok, session} = Store.lookup("proxy-token")
    assert session.authorization == "session-id"
    assert session.rules |> Enum.all?(&is_nil(&1.credential))
    assert session.unmatched_host_policy == :deny
  end

  test "lookup failures expose only bounded classifications and still refuse admission" do
    parent = self()
    handler = "lookup-evidence-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:remote_broker, :lookup],
      fn event, measurements, metadata, _ ->
        send(parent, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for status <- [301, 400, 401, 403, 404, 429, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, status, "secret-control-response")
      end)

      expected = if status == 403, do: :error, else: {:error, :unavailable}
      log = capture_log(fn -> assert ^expected = Store.lookup("secret-proxy-token") end)
      assert log =~ "outcome=http_error status=#{status}"
      refute log =~ "secret"

      assert_receive {[:remote_broker, :lookup], %{count: 1, elapsed_ms: elapsed},
                      %{outcome: :http_error, status: ^status}}

      assert elapsed >= 0
    end

    for body <- [%{expires_at: "secret-invalid-date"}, %{patterns: "secret-invalid-patterns"}] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, body))

      log =
        capture_log(fn -> assert {:error, :unavailable} = Store.lookup("secret-proxy-token") end)

      assert log =~ "outcome=invalid_response status=200"
      refute log =~ "secret"
      assert_receive {[:remote_broker, :lookup], _, %{outcome: :invalid_response, status: 200}}
    end

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    log =
      capture_log(fn -> assert {:error, :unavailable} = Store.lookup("secret-proxy-token") end)

    assert log =~ "outcome=timeout status=none"
    refute log =~ "secret"
    assert_receive {[:remote_broker, :lookup], _, %{outcome: :timeout, status: nil}}

    Req.Test.stub(__MODULE__, fn _ -> raise "secret-network-failure" end)

    log =
      capture_log(fn -> assert {:error, :unavailable} = Store.lookup("secret-proxy-token") end)

    assert log =~ "outcome=transport_error status=none"
    refute log =~ "secret"
    assert_receive {[:remote_broker, :lookup], _, %{outcome: :transport_error, status: nil}}
  end

  test "transport details use a fixed vocabulary without peer debug data" do
    for {error, detail} <- [
          {%Req.TransportError{reason: :closed}, :closed},
          {%Req.HTTPError{protocol: :http2, reason: :unprocessed}, :http2_unprocessed},
          {%Req.HTTPError{protocol: :http2, reason: :closed_for_writing},
           :http2_closed_for_writing},
          {%Req.HTTPError{protocol: :http2, reason: :too_many_concurrent_requests},
           :http2_concurrency_limit},
          {%Req.TransportError{reason: :econnreset}, :econnreset},
          {%Req.TransportError{reason: :nxdomain}, :nxdomain},
          {%Req.TransportError{reason: {:tls_alert, "secret-peer-debug"}}, :other},
          {%Req.HTTPError{protocol: :http2, reason: {:server_closed_request, :refused_stream}},
           :http2_refused_stream},
          {%Req.HTTPError{
             protocol: :http2,
             reason: {:server_closed_request, "secret-peer-debug"}
           }, :http2_stream_closed},
          {%Req.HTTPError{
             protocol: :http2,
             reason: {:server_closed_connection, :no_error, "secret-peer-debug"}
           }, :http2_connection_closed},
          {%Req.HTTPError{protocol: :http1, reason: "secret-peer-debug"}, :http1_error}
        ] do
      Process.put({ErrorAdapter, :error}, error)
      Application.put_env(:remote_broker, :request_options, adapter: ErrorAdapter)

      log =
        capture_log(fn -> assert {:error, :unavailable} = Store.lookup("secret-proxy-token") end)

      assert log =~ "outcome=transport_error status=none"
      assert log =~ "detail=#{detail}"
      refute log =~ "secret"
    end
  end

  test "authorization never falls back on transport failure, bad responses or denial" do
    request = %{
      host: "api.example.com",
      port: 443,
      target: "/secret",
      method: "GET",
      scheme: :https
    }

    for status <- [401, 403, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
      expected = if status == 403, do: :denied, else: :unavailable
      assert Store.authorize("session-id", request) == {:error, expected}
    end

    Req.Test.stub(__MODULE__, fn _ -> raise "network failure" end)
    assert Store.authorize("session-id", request) == {:error, :unavailable}

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{rules: [%{scheme: "unknown"}]}) end)

    assert Store.authorize("session-id", request) == {:error, :unavailable}
  end

  test "every admission calls home without sending sensitive request targets" do
    request = %{
      host: "api.example.com",
      port: 443,
      target: "/secret?key=value",
      method: "GET",
      scheme: :https
    }

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute body =~ "secret"
      refute body =~ "value"

      assert Jason.decode!(body) == %{
               "authorization" => "session-id",
               "host" => "api.example.com",
               "port" => 443
             }

      Req.Test.json(conn, %{
        rules: [
          %{
            name: "test",
            pattern: "api.example.com",
            scheme: "basic",
            credential: %{basic: ["user", "password"]}
          }
        ]
      })
    end)

    assert {:ok, [rule]} = Store.authorize("session-id", request)
    assert rule.credential == {"user", "password"}
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "{}") end)
    assert Store.authorize("session-id", request) == {:error, :denied}
  end
end
