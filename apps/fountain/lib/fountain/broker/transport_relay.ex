defmodule Fountain.Broker.TransportRelay do
  @moduledoc """
  Sandbox-local HTTP-to-TLS transport for HTTPS broker endpoints (ADR 0094).

  The relay knows only the upstream and conversation identity, never a session
  token. Clients retain proxy authentication in their process environment.
  """

  alias Fountain.Broker
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

        with :ok <- Sandbox.write_file(handle, staging, @script, mode: 0o600) do
          run(handle, staging, config)
        end

      _ ->
        :ok
    end
  end

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

    Sandbox.exec(
      handle,
      "flock",
      ["-w", "30", @lock, "bash", "-c", install, "relay", staging, @path, config],
      timeout: 45_000
    )
    |> result()
  end

  # Provider errors and child output can include command arguments. Return a
  # closed error vocabulary here; none of the relay's output is a request log.
  defp result({:ok, _, 0}), do: :ok
  defp result({:ok, _, _}), do: {:error, {:broker, :relay_unavailable}}
  defp result({:error, _}), do: {:error, {:broker, :relay_unreachable}}
end
