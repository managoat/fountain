defmodule Fountain.Broker.TransportRelay do
  @moduledoc """
  Sandbox-local HTTP-to-TLS transport for HTTPS broker endpoints (ADR 0089).

  The relay knows only the upstream and conversation identity, never a session
  token. Clients retain proxy authentication in their process environment.

  `ensure/2` reports `relay_write` and `relay_exec` as `provision_step` spans.
  On a fresh provision those are two of the five children of
  `broker_ca_install`, which is not a CA step alone (#2906);
  `scripts/load-test/README.md` records how they reconcile with it.
  """

  alias Fountain.Broker
  alias Fountain.Broker.SetupTiming
  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle

  @port 18_480
  @path "/tmp/fountain-broker-transport-relay.cjs"
  @lock "/tmp/fountain-broker-transport-relay.lock"
  @source Path.expand("../../../priv/broker/transport-relay.cjs", __DIR__)
  @external_resource @source
  @script File.read!(@source)
  @launcher Path.expand("../../../priv/broker/node-launch.sh", __DIR__)
  @external_resource @launcher
  @node_launcher File.read!(@launcher)

  @doc "The client-facing address; HTTP deployments keep their direct path."
  @spec client_uri(URI.t()) :: URI.t()
  def client_uri(%URI{scheme: "https"}),
    do: URI.parse("http://127.0.0.1:#{@port}")

  def client_uri(uri), do: uri

  @doc "Install and establish readiness before any sandbox network work."
  @spec ensure(Handle.t(), String.t()) :: :ok | {:error, term()}
  def ensure(handle, conversation_id) do
    case URI.parse(Broker.proxy_url()) do
      %URI{scheme: "https", host: host, port: port} ->
        staging = @path <> "." <> Ecto.UUID.generate()

        config =
          Jason.encode!(%{
            host: host,
            port: port,
            listen: @port,
            owner: conversation_id,
            ca: Broker.system_ca_bundle()
          })

        with :ok <- write_script(handle, staging) do
          run(handle, staging, config)
        end

      _ ->
        :ok
    end
  end

  # `relay_write` and `relay_exec`: the half of `broker_ca_install` that is
  # not CA work at all (#2906). The two are named without a parent prefix
  # because `ensure/2` also runs under the environment-layer build, where
  # there is no CA install to be a child of; the trace's nesting is what
  # establishes parentage. `Provisioning.install_broker_ca/2` adds `ca_pem`,
  # `ca_write` and `ca_exec` beside them, and
  # `scripts/load-test/README.md` records how the five reconcile with the
  # parent.
  #
  # Host monotonic, from `:telemetry.span`. The relay's own clocks ride
  # `relay_exec` as `sandbox_relay_*_ms`, measured with
  # `process.hrtime.bigint()` inside the sandbox. The gap between the span
  # and `sandbox_relay_total_ms` is a residual, not the provider round trip
  # alone: it also holds the outer `flock` wait, bash, `mv`, node start-up
  # (`sandbox_relay_boot_ms` measures that part) and process exit.
  defp step(handle, name, fun) do
    Fountain.Telemetry.span([:provision_step], %{step: name, provider: handle.provider}, fun)
  end

  defp write_script(handle, staging) do
    step(handle, "relay_write", fn ->
      result = Sandbox.write_file(handle, staging, @script, mode: 0o600)

      # The script is two orders of magnitude larger than the CA PEM, and on
      # Sprites an exec's arguments travel in a WebSocket URL's query string,
      # which is why this stays a file write. Its size is the number that
      # decides whether that is still true.
      {result, %{relay_script_bytes: byte_size(@script), outcome: outcome(result)}}
    end)
  end

  defp outcome(:ok), do: :ok
  defp outcome(_), do: :failed

  @doc "Stop before provider suspension; destruction removes the entire sandbox."
  @spec stop(Handle.t()) :: :ok | {:error, term()}
  def stop(handle) do
    if URI.parse(Broker.proxy_url()).scheme == "https", do: stop_existing(handle), else: :ok
  end

  defp stop_existing(handle) do
    # A machine provisioned before the relay has no script to run. The check
    # also keeps HTTP-only deployments free of a new Node dependency here.
    command =
      @node_launcher <>
        """
        if [ -f #{@path} ]; then exec flock -w 30 #{@lock} "$(relay_node)" #{@path} stop; fi
        """

    result(Sandbox.exec(handle, "bash", ["-c", command], timeout: 40_000))
  end

  defp run(handle, staging, config) do
    # Atomic replacement under the same lock as readiness and stop. A live
    # supervisor must never fork a partially rewritten worker script.
    install =
      @node_launcher <>
        ~S"""
        mv -f -- "$1" "$2" && exec "$(relay_node)" "$2" ensure "$3"
        """

    step(handle, "relay_exec", fn ->
      result =
        Sandbox.exec(
          handle,
          "flock",
          ["-w", "30", @lock, "bash", "-c", install, "relay", staging, @path, config],
          timeout: 45_000
        )

      # `ensure` prints only the fixed numeric phase clocks this parses; its
      # error path still prints no argument, URL or payload.
      case result do
        {:ok, out, 0} -> {:ok, Map.put(SetupTiming.attributes(out), :outcome, :ok)}
        {:ok, out, _} -> {result(result), Map.put(SetupTiming.attributes(out), :outcome, :failed)}
        {:error, _} -> {result(result), %{outcome: :failed}}
      end
    end)
  end

  # Provider errors and child output can include command arguments. Return a
  # closed error vocabulary here; none of the relay's output is a request log.
  defp result({:ok, _, 0}), do: :ok
  defp result({:ok, _, _}), do: {:error, {:broker, :relay_unavailable}}
  defp result({:error, _}), do: {:error, {:broker, :relay_unreachable}}
end
