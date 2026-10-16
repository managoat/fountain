defmodule Fountain.Broker.SetupTimingTest do
  use ExUnit.Case, async: true

  alias Fountain.Broker.SetupTiming

  test "exports the CA install's phases, branch and the relay's, labelled sandbox-side" do
    attributes =
      SetupTiming.attributes("""
      Updating certificates in /etc/ssl/certs...
      __MANAGOAT_BROKER__ ca_lock_wait 4 0
      __MANAGOAT_BROKER__ ca_verify 33 30
      __MANAGOAT_BROKER__ ca_rebuild 0
      __MANAGOAT_BROKER__ ca_reused 0
      __MANAGOAT_BROKER__ ca_trust 91 100
      __MANAGOAT_BROKER__ ca_sudoers 34 40
      __MANAGOAT_BROKER__ ca_total 162 170
      __MANAGOAT_BROKER__ relay_boot 41
      __MANAGOAT_BROKER__ relay_probe 6
      __MANAGOAT_BROKER__ relay_restart 0
      __MANAGOAT_BROKER__ relay_spawn 11
      __MANAGOAT_BROKER__ relay_warm 0
      __MANAGOAT_BROKER__ relay_polls 3
      __MANAGOAT_BROKER__ relay_ready 151
      __MANAGOAT_BROKER__ relay_total 169
      """)

    # Every duration carries the `sandbox_` prefix, because none of them
    # shares a clock with the host span that encloses it (#2908). The branch
    # and attempt counters are not durations and carry none. The CA's wall
    # figures are the values; the monotonic ones only check them.
    assert attributes == %{
             "sandbox_ca_lock_wait_ms" => 4,
             "sandbox_ca_verify_ms" => 33,
             "sandbox_ca_trust_ms" => 91,
             "sandbox_ca_sudoers_ms" => 34,
             "sandbox_ca_total_ms" => 162,
             "sandbox_ca_clock_checked" => 1,
             "sandbox_ca_clock_skew_max_ms" => 9,
             "sandbox_ca_timing_suspect" => 0,
             "sandbox_relay_boot_ms" => 41,
             "sandbox_relay_probe_ms" => 6,
             "sandbox_relay_spawn_ms" => 11,
             "sandbox_relay_ready_ms" => 151,
             "sandbox_relay_total_ms" => 169,
             "sandbox_relay_timing_suspect" => 0,
             "ca_rebuild" => 0,
             "ca_reused" => 0,
             "relay_restart" => 0,
             "relay_warm" => 0,
             "relay_polls" => 3
           }
  end

  test "ignores script output and lines that name no known field" do
    # The install runs with `stderr_to_stdout`, so whatever the trust-store
    # builder, sudo, visudo or git printed is in the same stream. None of it
    # may become an attribute, and a marker-shaped line naming a field this
    # module does not know must not mint one either.
    assert SetupTiming.attributes("""
           sudo: a password is required
           proxy=http://user:secret@127.0.0.1:18480
           __MANAGOAT_BROKER__ ca_pem_path /tmp/agent-vault-ca.crt
           __MANAGOAT_BROKER__ https://user:secret@example.com 1
           __MANAGOAT_BROKER__
           ca_total 91 91
           """) == %{}
  end

  describe "anomalous measurements are kept and flagged, never dropped (#2908)" do
    test "an implausible but bounded value keeps its number" do
      # A clock that stepped backwards, or a phase that outlasted any exec
      # deadline: the number is the evidence about the clock.
      assert SetupTiming.attributes("""
             __MANAGOAT_BROKER__ ca_trust -896 10
             __MANAGOAT_BROKER__ relay_ready 180001
             """) == %{
               "sandbox_ca_trust_ms" => -896,
               "sandbox_ca_clock_checked" => 1,
               "sandbox_ca_clock_skew_max_ms" => 906,
               "sandbox_ca_timing_suspect" => 1,
               "sandbox_relay_ready_ms" => 180_001,
               "sandbox_relay_timing_suspect" => 1
             }
    end

    test "an unreadable value is not exported but the phase still flags its script" do
      assert SetupTiming.attributes("""
             __MANAGOAT_BROKER__ ca_total 91ms 90
             __MANAGOAT_BROKER__ ca_verify
             __MANAGOAT_BROKER__ relay_total 1 2
             __MANAGOAT_BROKER__ relay_probe 99999999999
             """) == %{
               "sandbox_ca_clock_checked" => 0,
               "sandbox_ca_timing_suspect" => 1,
               "sandbox_relay_timing_suspect" => 1
             }
    end

    test "a phase the sandbox had no wall clock for is reported, not vanished" do
      # The script prints `-` where it could not read a clock rather than
      # printing nothing, so a phase that ran untimed is not mistaken for a
      # phase that never ran.
      assert SetupTiming.attributes("__MANAGOAT_BROKER__ ca_total - 120\n") == %{
               "sandbox_ca_clock_checked" => 0,
               "sandbox_ca_timing_suspect" => 1
             }
    end

    test "a wall clock that disagrees with the monotonic one beyond tolerance is suspect" do
      assert %{
               "sandbox_ca_total_ms" => 980,
               "sandbox_ca_clock_skew_max_ms" => 900,
               "sandbox_ca_timing_suspect" => 1,
               "sandbox_ca_clock_checked" => 1
             } = SetupTiming.attributes("__MANAGOAT_BROKER__ ca_total 980 80\n")

      # Within two /proc/uptime granules plus read jitter is agreement.
      assert %{"sandbox_ca_timing_suspect" => 0, "sandbox_ca_clock_skew_max_ms" => 50} =
               SetupTiming.attributes("__MANAGOAT_BROKER__ ca_total 70 20\n")
    end

    test "a malformed or out-of-range counter flags its script" do
      assert SetupTiming.attributes("""
             __MANAGOAT_BROKER__ relay_polls 1001
             __MANAGOAT_BROKER__ ca_rebuild 2
             """) == %{
               "sandbox_relay_timing_suspect" => 1,
               "sandbox_ca_timing_suspect" => 1
             }
    end
  end

  describe "sandbox_ca_clock_checked" do
    test "zero is sticky: a later checked phase cannot hide an earlier unchecked one" do
      attributes =
        SetupTiming.attributes("""
        __MANAGOAT_BROKER__ ca_lock_wait 2 -
        __MANAGOAT_BROKER__ ca_verify 30 30
        __MANAGOAT_BROKER__ ca_total 40 40
        """)

      # Every value is kept and none is anomalous; one phase simply had no
      # /proc/uptime reading to check it against.
      assert attributes["sandbox_ca_lock_wait_ms"] == 2
      assert attributes["sandbox_ca_total_ms"] == 40
      assert attributes["sandbox_ca_clock_checked"] == 0
      assert attributes["sandbox_ca_timing_suspect"] == 0
      assert attributes["sandbox_ca_clock_skew_max_ms"] == 0
    end

    test "an invalid cross-check is unchecked and suspect, never a valid check" do
      for mono <- ["-5", "abc", "99999999999"] do
        assert %{
                 "sandbox_ca_total_ms" => 40,
                 "sandbox_ca_clock_checked" => 0,
                 "sandbox_ca_timing_suspect" => 1
               } =
                 attributes = SetupTiming.attributes("__MANAGOAT_BROKER__ ca_total 40 #{mono}\n")

        refute Map.has_key?(attributes, "sandbox_ca_clock_skew_max_ms")
      end
    end

    test "a two-field CA phase is kept without a cross-check" do
      assert SetupTiming.attributes("__MANAGOAT_BROKER__ ca_total 40\n") == %{
               "sandbox_ca_total_ms" => 40,
               "sandbox_ca_clock_checked" => 0,
               "sandbox_ca_timing_suspect" => 0
             }
    end

    test "the relay's monotonic phases carry no checked signal" do
      refute Map.has_key?(
               SetupTiming.attributes("__MANAGOAT_BROKER__ relay_total 40\n"),
               "sandbox_ca_clock_checked"
             )
    end
  end

  test "a phase or counter reported twice keeps the first value and is flagged" do
    assert SetupTiming.attributes("""
           __MANAGOAT_BROKER__ ca_total 10 10
           __MANAGOAT_BROKER__ ca_total 9999 9999
           __MANAGOAT_BROKER__ relay_warm 1
           __MANAGOAT_BROKER__ relay_warm 0
           """) == %{
             "sandbox_ca_total_ms" => 10,
             "sandbox_ca_clock_checked" => 1,
             "sandbox_ca_clock_skew_max_ms" => 0,
             "sandbox_ca_timing_suspect" => 1,
             "relay_warm" => 1,
             "sandbox_relay_timing_suspect" => 1
           }
  end

  test "a zero is a measurement; a missing phase is not a zero" do
    attributes =
      SetupTiming.attributes("__MANAGOAT_BROKER__ ca_lock_wait 0 0\n")

    assert attributes["sandbox_ca_lock_wait_ms"] == 0
    refute Map.has_key?(attributes, "sandbox_ca_total_ms")
  end

  test "no timed phase means no signals at all" do
    # A contended lock exits before any phase: absent, not a clean zero.
    assert SetupTiming.attributes("flock: timed out\n") == %{}
    assert SetupTiming.attributes("__MANAGOAT_BROKER__ ca_reused 1\n") == %{"ca_reused" => 1}
  end

  test "non-binary output yields no attributes rather than raising" do
    assert SetupTiming.attributes(nil) == %{}
    assert SetupTiming.attributes(:timeout) == %{}
  end

  describe "strip/1" do
    test "removes only the marker lines, so a failure keeps its reason" do
      # `install_broker_ca/2` quotes the first 500 bytes of output as the
      # failure reason. Eight markers are ~250 of them, so without this the
      # instrumentation would push the diagnosis out of the error it is
      # supposed to help explain.
      output =
        """
        __MANAGOAT_BROKER__ ca_lock_wait 4
        __MANAGOAT_BROKER__ ca_verify 33
        sudo: unable to resolve host agent-sprite
        __MANAGOAT_BROKER__ ca_trust 91
        update-ca-certificates: failed to write bundle
        """

      assert SetupTiming.strip(output) ==
               """
               sudo: unable to resolve host agent-sprite
               update-ca-certificates: failed to write bundle
               """

      assert String.slice(SetupTiming.strip(output), 0, 40) =~ "sudo: unable to resolve host"
    end

    test "a line that merely mentions the marker is not a marker line" do
      assert SetupTiming.strip("saw __MANAGOAT_BROKER__ in the output\n") ==
               "saw __MANAGOAT_BROKER__ in the output\n"
    end

    test "non-binary output is stringified, never dropped" do
      assert SetupTiming.strip(:timeout) == "timeout"
    end
  end
end
