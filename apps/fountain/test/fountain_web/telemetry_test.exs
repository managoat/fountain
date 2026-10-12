defmodule FountainWeb.TelemetryTest do
  # Pure wiring assertions — no DB, no poller started.
  use ExUnit.Case, async: true

  describe "periodic_measurements/1" do
    test "defaults to the test-env flag, which disables polling" do
      # config/test.exs sets gauge_poller_enabled: false so the poller's
      # Repo calls can't race the SQL Sandbox. If this ever flips on in
      # test, async suites start flaking on connection ownership.
      assert FountainWeb.Telemetry.periodic_measurements() == []
    end

    test "when enabled, polls the ops gauges" do
      measurements = FountainWeb.Telemetry.periodic_measurements(true)

      assert {Fountain.OpsGauges, :emit_telemetry, []} in measurements
    end

    test "every polled MFA exists — a missing one crashes telemetry_poller at boot" do
      # The emitter modules are tested directly, so a rename there passes
      # its own tests while the poller list — empty in every env where the
      # suite runs — still points at the old name. This is the joint check:
      # the production list must reference functions that exist.
      for {mod, fun, args} <- FountainWeb.Telemetry.periodic_measurements(true) do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} is not loadable"

        assert function_exported?(mod, fun, length(args)),
               "#{inspect(mod)}.#{fun}/#{length(args)} is not exported — " <>
                 "telemetry_poller would crash at boot in prod"
      end
    end
  end
end
