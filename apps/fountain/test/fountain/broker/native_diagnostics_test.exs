defmodule Fountain.Broker.Native.DiagnosticsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Fountain.Broker.Native.Diagnostics

  @meta %{
    event: :progress,
    phase: :serving,
    client_writing: true,
    connection_id: "connection-123",
    host: "registry.npmjs.org",
    port: 443,
    meta: %{"conversation_id" => "conversation-123", "token" => "do-not-log"},
    path: "/do-not-log?token=do-not-log",
    headers: %{"authorization" => "do-not-log"},
    body: "do-not-log",
    error: {:tls_alert, "do-not-log"}
  }

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  test "a pending transfer idle past the stall window warns without secret-bearing fields" do
    measurements = %{
      duration: native(90_000),
      upstream_idle: native(Diagnostics.stall_ms() + 1_000),
      client_write_in_flight: 0,
      upstream_bytes: 1200,
      pending_requests: 1,
      secret_measurement: "do-not-log"
    }

    log =
      capture_log(fn ->
        assert :ok = Diagnostics.handle(nil, measurements, @meta, nil)
      end)

    assert log =~ "stalled transfer conv conversation-123 connection connection-123"
    assert log =~ "registry.npmjs.org:443"
    assert log =~ "upstream_idle_ms 31000"
    refute log =~ "do-not-log"
  end

  test "a blocked client write past the stall window warns" do
    measurements = %{
      duration: native(40_000),
      upstream_idle: native(10),
      client_write_in_flight: native(Diagnostics.stall_ms()),
      pending_requests: 1
    }

    assert capture_log(fn -> Diagnostics.handle(nil, measurements, @meta, nil) end) =~
             "client_write_blocked_ms 30000"
  end

  test "healthy samples, idle tunnels and other events log nothing" do
    healthy = %{duration: native(60_000), upstream_idle: native(50), pending_requests: 2}
    idle = %{duration: native(600_000), upstream_idle: native(600_000), pending_requests: 0}

    log =
      capture_log(fn ->
        assert :ok = Diagnostics.handle(nil, healthy, @meta, nil)
        assert :ok = Diagnostics.handle(nil, idle, @meta, nil)
        assert :ok = Diagnostics.handle(nil, %{duration: 1}, %{@meta | event: :stop}, nil)
        assert :ok = Diagnostics.handle(nil, %{duration: 1}, %{@meta | event: :phase}, nil)
      end)

    assert log == ""
  end

  test "a malformed event does not detach the handler or log its contents" do
    log =
      capture_log(fn ->
        assert :ok =
                 Diagnostics.handle(
                   nil,
                   %{pending_requests: 1, upstream_idle: native(60_000)},
                   %{event: :progress, meta: "secret"},
                   nil
                 )
      end)

    refute log =~ "secret"
  end
end
