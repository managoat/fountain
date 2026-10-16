defmodule Fountain.Broker.Native.DiagnosticsTest do
  # Capturing info logs requires changing the suite's global warning-level filter.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Fountain.Broker.Native.Diagnostics

  test "connection timing logs correlate the conversation and exclude secret-bearing fields" do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    measurements = %{
      duration: System.convert_time_unit(123, :millisecond, :native),
      client_write_in_flight: System.convert_time_unit(45, :millisecond, :native),
      upstream_bytes: 1200,
      client_bytes: 0,
      pending_requests: 1,
      secret_measurement: "do-not-log"
    }

    meta = %{
      event: :progress,
      phase: :serving,
      client_writing: true,
      connection_id: "connection-123",
      request_id: "connection-123:1",
      host: "registry.npmjs.org",
      port: 443,
      meta: %{"conversation_id" => "conversation-123", "token" => "do-not-log"},
      path: "/do-not-log?token=do-not-log",
      headers: %{"authorization" => "do-not-log"},
      body: "do-not-log",
      error: {:tls_alert, "do-not-log"}
    }

    log =
      capture_log([level: :info], fn ->
        assert :ok = Diagnostics.handle(nil, measurements, meta, nil)
      end)

    assert log =~ "conv conversation-123 connection connection-123"
    assert log =~ "registry.npmjs.org:443"
    assert log =~ ~s("duration_ms" => 123)
    assert log =~ ~s("client_write_in_flight_ms" => 45)
    assert log =~ "upstream_bytes: 1200" or log =~ ":upstream_bytes => 1200"
    assert log =~ "connection-123:1"
    refute log =~ "do-not-log"
  end

  test "malformed events do not detach the handler or log their contents" do
    log =
      capture_log(fn ->
        assert :ok = Diagnostics.handle(nil, %{}, %{meta: "secret"}, nil)
      end)

    assert log =~ "diagnostic event skipped"
    refute log =~ "secret"
  end
end
