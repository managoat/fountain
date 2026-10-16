defmodule Fountain.BrokerTransportRelayTest do
  # Broker.proxy_env calls its own configuration reader directly. These tests
  # change application configuration, so they cannot run beside other tests.
  use ExUnit.Case, async: false
  use Mimic

  alias Fountain.Broker
  alias Fountain.Broker.TransportRelay
  alias Managoat.Sandbox.Handle

  setup do
    previous = Application.fetch_env!(:fountain, :broker_proxy_url)
    on_exit(fn -> Application.put_env(:fountain, :broker_proxy_url, previous) end)
  end

  test "HTTP deployments retain their direct authenticated proxy URL" do
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.example:8080")

    assert {"HTTPS_PROXY", "http://token:vault@broker.example:8080"} in Broker.proxy_env(%{
             token: "token",
             vault: "vault"
           })

    reject(&Managoat.Sandbox.Sprites.write_file/4)
    assert :ok = TransportRelay.ensure(%Handle{provider: :sprites, name: "s"}, "conv")
  end

  test "HTTPS deployments keep authentication process-only on a loopback HTTP URL" do
    Application.put_env(:fountain, :broker_proxy_url, "https://broker.example:443")
    pairs = Broker.proxy_env(%{token: "secret-token", vault: "vault"})
    assert {"HTTPS_PROXY", "http://secret-token:vault@127.0.0.1:18480"} in pairs
    assert Broker.proxy_secrets(pairs) == ["secret-token"]

    assert Fountain.Conversations.Identity.disk_env(pairs) == [
             {"NO_PROXY", "localhost,127.0.0.1"}
           ]
  end

  test "readiness command contains only upstream configuration, never session credentials" do
    stub(Broker, :proxy_url, fn -> "https://broker.example:443" end)
    handle = %Handle{provider: :sprites, name: "s"}

    expect(Managoat.Sandbox.Sprites, :write_file, fn ^handle, _, script, _ ->
      assert script =~ "rejectUnauthorized: true"
      :ok
    end)

    expect(Managoat.Sandbox.Sprites, :exec, fn ^handle, "flock", args, _ ->
      config = args |> List.last() |> Jason.decode!()

      assert config == %{
               "host" => "broker.example",
               "port" => 443,
               "listen" => 18_480,
               "owner" => "conv",
               "ca" => Broker.system_ca_bundle()
             }

      {:ok, "", 0}
    end)

    assert :ok = TransportRelay.ensure(handle, "conv")
  end

  test "ensure reports its write and exec as steps, wherever it is called from" do
    # Under a fresh provision these are two of the five children of
    # `broker_ca_install` (#2906). `ensure/2` also runs under an
    # environment-layer build, which has no CA install to be a child of, so
    # the names carry no parent prefix and the trace's nesting is what says
    # whose children they are.
    stub(Broker, :proxy_url, fn -> "https://broker.example:443" end)
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:fountain, :provision_step, :stop],
      fn _, _, metadata, _ -> send(test, {:step, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    stub(Managoat.Sandbox.Sprites, :write_file, fn _, _, _, _ -> :ok end)

    stub(Managoat.Sandbox.Sprites, :exec, fn _, "flock", _, _ ->
      {:ok, "__MANAGOAT_BROKER__ relay_warm 1\n__MANAGOAT_BROKER__ relay_total 48\n", 0}
    end)

    assert :ok = TransportRelay.ensure(%Handle{provider: :sprites, name: "s"}, "conv")

    assert_received {:step, %{step: "relay_write", provider: :sprites} = write}
    assert write.relay_script_bytes > 1_000
    assert write.outcome == :ok

    assert_received {:step, %{step: "relay_exec", provider: :sprites} = exec}
    assert exec["relay_warm"] == 1
    assert exec["sandbox_relay_total_ms"] == 48
    assert exec.outcome == :ok

    # An HTTP deployment runs no relay at all, so it reports no steps.
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.example:8080")
    stub(Broker, :proxy_url, fn -> "http://broker.example:8080" end)
    assert :ok = TransportRelay.ensure(%Handle{provider: :sprites, name: "s"}, "conv")
    refute_received {:step, _}
  end

  @tag timeout: 90_000
  test "real TLS transport, lifecycle, supervisor and certificate rejection" do
    path = Path.expand("../broker_transport_relay.test.cjs", __DIR__)
    # Stream progress so a child that outlives ExUnit's deadline still leaves
    # its last completed subtest in the CI log (#2890).
    {_output, status} =
      System.cmd("node", ["--test", "--test-reporter=spec", path],
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )

    assert status == 0
  end
end
