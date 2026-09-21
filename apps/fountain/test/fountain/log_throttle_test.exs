defmodule Fountain.LogThrottleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fountain.LogThrottle

  test "a key logs once, however often it is asked; another key is not held back by it" do
    key = {:log_throttle_test, make_ref()}
    other = {:log_throttle_test, make_ref()}

    log =
      capture_log(fn ->
        for _ <- 1..50, do: assert(:ok = LogThrottle.warning(key, "the first key failed"))
        assert :ok = LogThrottle.warning(other, "the second key failed")
      end)

    assert length(String.split(log, "the first key failed")) == 2
    assert log =~ "the second key failed"
  end

  test "error/2 is the same at error, and shares the key's minute with warning/2" do
    key = {:log_throttle_test, make_ref()}

    log =
      capture_log(fn ->
        for _ <- 1..5, do: assert(:ok = LogThrottle.error(key, "the outage"))
        assert :ok = LogThrottle.warning(key, "the outage, as a warning")
      end)

    assert log =~ "[error] the outage"
    assert length(String.split(log, "the outage")) == 2
  end

  test "a key that logged more than a minute ago logs again, and the table forgets the old" do
    key = {:log_throttle_test, make_ref()}
    stale = {:log_throttle_test, make_ref()}
    long_ago = System.monotonic_time(:millisecond) - 61_000

    assert capture_log(fn -> LogThrottle.warning(key, "again") end) =~ "again"
    :ets.insert(:fountain_log_throttle, [{key, long_ago}, {stale, long_ago}])

    assert capture_log(fn -> LogThrottle.warning(key, "again") end) =~ "again"
    assert :ets.lookup(:fountain_log_throttle, stale) == []
  end
end
