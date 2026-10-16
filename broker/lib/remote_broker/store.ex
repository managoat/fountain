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
        report_lookup(started, :ok, 200, :none)
        {:ok, session}

      {:error, reason, status} ->
        report_lookup(started, reason, status, transport_detail(response))
        # Only the authenticated control endpoint's 403 means this session
        # was rejected. A 401 rejects the broker's deployment credential,
        # not the sandbox token; all other failures leave authority unknown.
        if reason == :http_error and status == 403, do: :error, else: {:error, :unavailable}
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

  # A fixed subtype, never inspect(reason): TLS alerts and HTTP/2 GOAWAY
  # debug data can contain arbitrary peer-supplied text.
  defp transport_detail({:error, %Req.TransportError{reason: reason}})
       when reason in [:closed, :econnreset, :econnrefused, :nxdomain, :enetunreach, :timeout],
       do: reason

  defp transport_detail(
         {:error,
          %Req.HTTPError{protocol: :http2, reason: {:server_closed_request, :refused_stream}}}
       ),
       do: :http2_refused_stream

  defp transport_detail(
         {:error, %Req.HTTPError{protocol: :http2, reason: {:server_closed_request, _}}}
       ),
       do: :http2_stream_closed

  defp transport_detail(
         {:error, %Req.HTTPError{protocol: :http2, reason: {:server_closed_connection, _, _}}}
       ),
       do: :http2_connection_closed

  @http2_details %{
    closed: :http2_closed,
    closed_for_writing: :http2_closed_for_writing,
    too_many_concurrent_requests: :http2_concurrency_limit,
    unprocessed: :http2_unprocessed
  }

  defp transport_detail({:error, %Req.HTTPError{protocol: :http2, reason: reason}})
       when is_map_key(@http2_details, reason),
       do: Map.fetch!(@http2_details, reason)

  defp transport_detail({:error, %Req.HTTPError{protocol: :http1}}), do: :http1_error
  defp transport_detail({:error, %Req.HTTPError{protocol: :http2}}), do: :http2_error
  defp transport_detail({:error, :unavailable}), do: :control_exception
  defp transport_detail({:error, _}), do: :other
  defp transport_detail(_), do: :none

  # No token, session ID, receipt, body, URL or raw exception enters evidence.
  # Both lookup failure results refuse admission; only rejected sessions challenge.
  defp report_lookup(started, outcome, status, detail) do
    elapsed_ms = max(0, System.monotonic_time(:millisecond) - started)

    :telemetry.execute(
      [:remote_broker, :lookup],
      %{count: 1, elapsed_ms: elapsed_ms},
      %{outcome: outcome, status: status, detail: detail}
    )

    if outcome != :ok do
      Logger.warning(
        "remote broker: lookup failed outcome=#{outcome} status=#{status || "none"} elapsed_ms=#{elapsed_ms} detail=#{detail}"
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
