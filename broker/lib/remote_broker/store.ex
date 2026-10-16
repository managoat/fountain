defmodule RemoteBroker.Store do
  @moduledoc "No credential cache: every HTTP admission consults home, including inside CONNECT."
  @behaviour Managoat.Broker.Store
  alias Managoat.Broker.{Rule, Session}
  require Logger

  @schemes %{
    "bearer" => :bearer,
    "basic" => :basic,
    "api_key" => :api_key,
    "custom" => :custom,
    "substitute" => :substitute,
    "passthrough" => :passthrough
  }

  @impl true
  def lookup(token) do
    started = System.monotonic_time(:millisecond)
    response = RemoteBroker.Control.request("lookup", %{token: token})

    case decode_lookup(response) do
      {:ok, session} ->
        report_lookup(started, :ok, 200)
        {:ok, session}

      {:error, reason, status} ->
        report_lookup(started, reason, status)
        :error
    end
  end

  defp decode_lookup({:ok, %{status: 200, body: body}}) do
    with {:ok, expires, _} <- DateTime.from_iso8601(body["expires_at"]),
         policy when policy in ["deny", "passthrough"] <- body["policy"],
         id when is_binary(id) <- body["authorization"],
         receipt when is_binary(receipt) <- body["receipt"] do
      {:ok,
       %Session{
         authorization: id,
         expires_at: expires,
         unmatched_host_policy: if(policy == "deny", do: :deny, else: :passthrough),
         rules: Enum.map(body["patterns"], &%Rule{pattern: &1, scheme: :passthrough}),
         meta: %{"receipt" => receipt}
       }}
    else
      _ -> {:error, :invalid_response, 200}
    end
  rescue
    _ -> {:error, :invalid_response, 200}
  end

  defp decode_lookup({:ok, %{status: status}}) when status in 100..599,
    do: {:error, :http_error, status}

  defp decode_lookup({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, :timeout, nil}

  defp decode_lookup({:error, _}), do: {:error, :transport_error, nil}
  defp decode_lookup(_), do: {:error, :invalid_response, nil}

  # No token, session ID, receipt, body, URL or raw exception enters evidence.
  # The proxy's Store contract still returns :error and refuses admission.
  defp report_lookup(started, outcome, status) do
    elapsed_ms = max(0, System.monotonic_time(:millisecond) - started)

    :telemetry.execute(
      [:remote_broker, :lookup],
      %{count: 1, elapsed_ms: elapsed_ms},
      %{outcome: outcome, status: status}
    )

    if outcome != :ok do
      Logger.warning(
        "remote broker: lookup failed outcome=#{outcome} status=#{status || "none"} elapsed_ms=#{elapsed_ms}"
      )
    end
  end

  @impl true
  def authorize(id, request) do
    case RemoteBroker.Control.request("authorize", %{
           authorization: id,
           host: request.host,
           port: request.port
         }) do
      {:ok, %{status: 200, body: %{"rules" => rules}}} when is_list(rules) ->
        {:ok, Enum.map(rules, &decode/1)}

      {:ok, %{status: 403}} ->
        {:error, :denied}

      _ ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp decode(map) do
    %Rule{
      name: map["name"],
      pattern: map["pattern"],
      scheme: Map.fetch!(@schemes, map["scheme"]),
      credential: credential(map["credential"]),
      header: map["header"],
      prefix: map["prefix"] || "",
      template: map["template"] || %{},
      placeholder: map["placeholder"]
    }
  end

  defp credential(%{"basic" => [user, pass]}), do: {user, pass}
  defp credential(value), do: value
end
