defmodule FountainWeb.Plugs.BrokerControl do
  @moduledoc """
  Private, deployment-authenticated broker protocol. Runs before request
  logging, parameter parsing and Sentry: session tokens and credentials must
  never enter those pipelines. This is not an account API.
  """
  @behaviour Plug
  import Plug.Conn
  alias Fountain.Broker.Native.{RequestLog, Sessions}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: ["internal", "broker", "v1", action]} = conn, opts) do
    token = Keyword.get(opts, :token, Application.get_env(:fountain, :broker_control_token))

    if authorized?(conn, token) do
      dispatch(conn, action)
    else
      respond(conn, 401, %{"error" => "unauthorized"})
    end
  end

  def call(conn, _opts), do: conn

  defp authorized?(conn, token) when is_binary(token) and byte_size(token) >= 32 do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] -> Plug.Crypto.secure_compare(token, supplied)
      _ -> false
    end
  end

  defp authorized?(_conn, _token), do: false

  defp dispatch(%{method: "POST"} = conn, action) do
    with {:ok, body, conn} <-
           read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 2_000),
         {:ok, params} when is_map(params) <- Jason.decode(body) do
      result(conn, perform(action, params))
    else
      _ -> respond(conn, 400, %{"error" => "invalid_request"})
    end
  end

  defp dispatch(conn, _action), do: respond(conn, 405, %{"error" => "method_not_allowed"})

  defp perform("lookup", %{"token" => token}) when is_binary(token) and byte_size(token) <= 128,
    do: Sessions.remote_lookup(token)

  defp perform("authorize", %{"authorization" => id, "host" => host, "port" => port})
       when is_binary(id) and is_binary(host) and byte_size(host) <= 255 and
              is_integer(port) and port in 1..65_535,
       do: Sessions.remote_authorize(id, host, port)

  defp perform("events", %{"events" => events}) when is_list(events) and length(events) <= 100 do
    Enum.each(events, &record/1)
    {:ok, %{}}
  end

  defp perform(_action, _params), do: {:error, :invalid}

  # A signed receipt preserves server-established tenant/conversation binding
  # after revocation, including a stream that finishes after its session ends.
  # No remote-provided user id, path, header, credential or free-form error is stored.
  defp record(%{"receipt" => receipt} = event) when is_binary(receipt) do
    with {:ok, meta} <-
           Phoenix.Token.verify(FountainWeb.Endpoint, "remote-broker-log-v1", receipt,
             max_age: 604_800
           ),
         %{"user_id" => user, "conversation_id" => conv} <- meta,
         method
         when method in ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT"] <-
           event["method"],
         host when is_binary(host) and byte_size(host) <= 255 <- event["host"],
         outcome when outcome in ["injected", "passthrough", "denied", "error"] <-
           event["outcome"] do
      service = event["service"]
      keys = get_in(meta, ["credential_keys", service]) || []

      RequestLog.record(%{
        user_id: user,
        conversation_id: conv,
        method: method,
        host: host,
        path: RequestLog.redacted_path(),
        outcome: outcome,
        service: if(keys != [], do: service),
        credential_keys: keys,
        status: bounded(event["status"], 100, 599),
        latency_ms: bounded(event["latency_ms"], 0, 2_147_483_647),
        error: if(event["failed"] == true, do: "remote_forwarding_failed"),
        inserted_at: DateTime.utc_now()
      })
    else
      _ -> :ok
    end
  end

  defp record(_), do: :ok
  defp bounded(n, low, high) when is_integer(n) and n >= low and n <= high, do: n
  defp bounded(_, _, _), do: nil
  defp result(conn, {:ok, body}), do: respond(conn, 200, body)
  defp result(conn, {:error, :denied}), do: respond(conn, 403, %{"error" => "denied"})
  defp result(conn, {:error, :unavailable}), do: respond(conn, 503, %{"error" => "unavailable"})
  defp result(conn, _), do: respond(conn, 400, %{"error" => "invalid_request"})

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
