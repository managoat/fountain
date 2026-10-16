defmodule Fountain.Broker.SetupTimingTest do
  use ExUnit.Case, async: true

  alias Fountain.Broker.SetupTiming

  test "exports the CA install's phases, branch and the relay's, labelled sandbox-side" do
    attributes =
      SetupTiming.attributes("""
      Updating certificates in /etc/ssl/certs...
      __MANAGOAT_BROKER__ ca_lock_wait 4
      __MANAGOAT_BROKER__ ca_verify 33
      __MANAGOAT_BROKER__ ca_rebuild 0
      __MANAGOAT_BROKER__ ca_reused 0
      __MANAGOAT_BROKER__ ca_trust 91
      __MANAGOAT_BROKER__ ca_sudoers 34
      __MANAGOAT_BROKER__ ca_total 162
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
    # and attempt counters are not durations and carry none.
    assert attributes == %{
             "sandbox_ca_lock_wait_ms" => 4,
             "sandbox_ca_verify_ms" => 33,
             "sandbox_ca_trust_ms" => 91,
             "sandbox_ca_sudoers_ms" => 34,
             "sandbox_ca_total_ms" => 162,
             "sandbox_relay_probe_ms" => 6,
             "sandbox_relay_spawn_ms" => 11,
             "sandbox_relay_ready_ms" => 151,
             "sandbox_relay_total_ms" => 169,
             "ca_rebuild" => 0,
             "ca_reused" => 0,
             "relay_restart" => 0,
             "relay_warm" => 0,
             "relay_polls" => 3
           }
  end

  test "ignores script output, unknown fields, bad numbers and partial records" do
    # The install runs with `stderr_to_stdout`, so whatever the trust-store
    # builder, sudo, visudo or git printed is in the same stream. None of it
    # may become an attribute, and an attacker-controlled line that looks
    # like a marker must not mint one either.
    assert SetupTiming.attributes("""
           sudo: a password is required
           proxy=http://user:secret@127.0.0.1:18480
           __MANAGOAT_BROKER__ ca_pem_path /tmp/agent-vault-ca.crt
           __MANAGOAT_BROKER__ ca_trust -1
           __MANAGOAT_BROKER__ ca_trust 180001
           __MANAGOAT_BROKER__ relay_polls 1001
           __MANAGOAT_BROKER__ ca_total 91ms
           __MANAGOAT_BROKER__ ca_total
           __MANAGOAT_BROKER__ ca_total 1 2
           __MANAGOAT_BROKER__
           ca_total 91
           """) == %{}
  end

  test "a phase reported twice keeps the first value" do
    assert SetupTiming.attributes("""
           __MANAGOAT_BROKER__ ca_total 10
           __MANAGOAT_BROKER__ ca_total 9999
           """) == %{"sandbox_ca_total_ms" => 10}
  end

  test "a zero is a measurement; a missing phase is not a zero" do
    attributes =
      SetupTiming.attributes("__MANAGOAT_BROKER__ ca_lock_wait 0\n")

    assert attributes == %{"sandbox_ca_lock_wait_ms" => 0}
    refute Map.has_key?(attributes, "sandbox_ca_total_ms")
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
