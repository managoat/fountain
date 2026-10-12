defmodule Fountain.TelemetryTickTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fountain.TelemetryTick

  # Regression tests for #395: the #365 guard was rescue-only, but
  # telemetry_poller drops a measurement that fails in ANY class — and the
  # class Repo actually produces under a checkout timeout or a dying pool
  # is an exit. The existing #365 tests force a raise, which rescue already
  # covered, so they passed with the exit hole open.

  test "a raising tick is skipped" do
    log = capture_log(fn -> assert TelemetryTick.run("t", fn -> raise "boom" end) == :ok end)
    assert log =~ "t tick skipped: boom"
  end

  test "an exiting tick is skipped — the class Repo produces (#395)" do
    log =
      capture_log(fn ->
        assert TelemetryTick.run("t", fn ->
                 exit({:timeout, {DBConnection.Holder, :checkout, []}})
               end) == :ok
      end)

    assert log =~ "t tick skipped"
    assert log =~ ":timeout"
  end

  test "a throwing tick is skipped" do
    log = capture_log(fn -> assert TelemetryTick.run("t", fn -> throw(:oops) end) == :ok end)
    assert log =~ "t tick skipped"
    assert log =~ ":oops"
  end

  test "a healthy tick returns :ok and logs nothing" do
    log = capture_log(fn -> assert TelemetryTick.run("t", fn -> :fine end) == :ok end)
    refute log =~ "skipped"
  end

  # The wiring half: the poller measurement functions must run through the
  # guard. String-level rather than behavioral because forcing a genuine
  # Repo exit deterministically in a sandboxed test is not possible — and a
  # future refactor that reintroduces a bare rescue is exactly what this
  # catches.
  test "the ops gauges tick runs through the guard" do
    # Umbrella tests run with cwd at the app root.
    for source <- ["lib/fountain/ops_gauges.ex"] do
      assert File.read!(source) =~ "Fountain.TelemetryTick.run(",
             "#{source} no longer routes its poller tick through Fountain.TelemetryTick (#395)"
    end
  end
end
