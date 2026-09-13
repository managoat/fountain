defmodule Fountain.HTTP do
  @moduledoc "Bearer-authenticated JSON HTTP with an injectable transport."

  alias Fountain.{Config, Error}

  @user_agent "fountain-sdk-elixir/0.2.1"
  defstruct [:config, :transport, timeout: 30_000]

  @type t :: %__MODULE__{config: Config.t(), transport: module(), timeout: timeout()}

  def user_agent, do: @user_agent

  def new(%Config{} = config, opts \\ []) do
    %__MODULE__{
      config: config,
      transport: Keyword.get(opts, :transport, Fountain.HTTP.Finch),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  def base_url(%__MODULE__{config: config}), do: config.base_url

  def url(%__MODULE__{config: config}, path, query \\ []) do
    base =
      if String.starts_with?(path, ["http://", "https://"]) do
        unless same_origin?(path, config.base_url),
          do:
            raise(Error,
              message: "absolute request URLs must have the configured Fountain origin",
              kind: :validation
            )

        path
      else
        config.base_url <> "/" <> String.trim_leading(path, "/")
      end

    values =
      query
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.map(fn {key, value} -> {to_string(key), query_value(value)} end)

    if values == [],
      do: base,
      else:
        base <> if(String.contains?(base, "?"), do: "&", else: "?") <> URI.encode_query(values)
  end

  def headers(http, extra \\ [])

  def headers(%__MODULE__{config: %{api_key: ""}}, _extra),
    do:
      {:error,
       %Error{
         message:
           "No Fountain API key. Pass :api_key, set FOUNTAIN_API_KEY, or run `fountain auth login`.",
         kind: :auth
       }}

  def headers(%__MODULE__{config: config}, extra) do
    base = [
      {"authorization", "Bearer #{config.api_key}"},
      {"accept", "application/json"},
      {"user-agent", @user_agent}
    ]

    base =
      if config.parent_conversation_id,
        do: [{"x-fountain-parent-conversation-id", config.parent_conversation_id} | base],
        else: base

    {:ok, merge_headers(base, extra)}
  end

  @doc "Sends an HTTP request and returns its decoded JSON (or text) body."
  def request(%__MODULE__{} = http, method, path, opts \\ []) do
    url = url(http, path, opts[:query] || [])
    method = method |> to_string() |> String.upcase()

    with {:ok, headers} <- headers(http, opts[:headers] || []),
         {:ok, encoded, headers} <- encode_body(opts[:body], headers),
         {:ok, status, response_headers, raw} <-
           http.transport.request(
             method,
             url,
             put_accept(headers, opts[:accept]),
             encoded,
             Keyword.get(opts, :timeout, http.timeout)
           ) do
      body = decode_body(raw)

      if status in 200..299,
        do: {:ok, body},
        else: {:error, Error.for_status(status, body, method, url, response_headers)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, connection_error(method, url, reason)}
    end
  rescue
    error in [Error] -> {:error, error}
    error -> {:error, connection_error(to_string(method), to_string(path), error)}
  end

  def request!(http, method, path, opts \\ []) do
    case request(http, method, path, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  def data(http, method, path, opts \\ []) do
    with {:ok, body} <- request(http, method, path, opts),
         do: {:ok, if(is_map(body), do: body["data"], else: nil)}
  end

  def data!(http, method, path, opts \\ []),
    do: request!(http, method, path, opts) |> then(&if(is_map(&1), do: &1["data"], else: nil))

  def list(http, path, opts \\ []) do
    with {:ok, value} <- data(http, "GET", path, opts),
         do: {:ok, if(is_list(value), do: value, else: [])}
  end

  def list!(http, path, opts \\ []) do
    case list(http, path, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  @doc false
  def stream(%__MODULE__{} = http, method, path, opts, on_chunk) do
    url = url(http, path, opts[:query] || [])
    method = method |> to_string() |> String.upcase()

    with {:ok, headers} <- headers(http, opts[:headers] || []) do
      result =
        http.transport.stream(
          method,
          url,
          put_accept(headers, opts[:accept] || "text/event-stream"),
          Keyword.get(opts, :timeout, :infinity),
          on_chunk
        )

      case result do
        {:ok, status, response_headers, response_body} ->
          stream_status(status, response_headers, response_body, method, url)

        {:ok, status, response_headers} ->
          stream_status(status, response_headers, nil, method, url)

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, connection_error(method, url, reason)}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, connection_error(method, url, reason)}
    end
  end

  defp stream_status(status, _headers, _body, _method, _url) when status in 200..299,
    do: :ok

  defp stream_status(status, headers, body, method, url),
    do: {:error, Error.for_status(status, decode_body(body), method, url, headers)}

  def decode_body(raw) when raw in [nil, ""], do: nil

  def decode_body(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> value
      _ -> raw
    end
  end

  defp encode_body(nil, headers), do: {:ok, nil, headers}

  defp encode_body(body, headers) do
    case Jason.encode(body) do
      {:ok, value} ->
        {:ok, value, merge_headers(headers, [{"content-type", "application/json"}])}

      {:error, reason} ->
        {:error,
         %Error{
           message: "could not JSON encode request body: #{inspect(reason)}",
           kind: :validation
         }}
    end
  end

  defp query_value(true), do: "true"
  defp query_value(false), do: "false"
  defp query_value(value) when is_list(value), do: Enum.join(value, ",")
  defp query_value(value), do: to_string(value)

  defp same_origin?(left, right) do
    left = URI.parse(left)
    right = URI.parse(right)

    {left.scheme, left.host, left.port || default_port(left.scheme)} ==
      {right.scheme, right.host, right.port || default_port(right.scheme)}
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: nil

  defp put_accept(headers, nil), do: headers
  defp put_accept(headers, accept), do: merge_headers(headers, [{"accept", accept}])

  defp merge_headers(left, right) do
    (left ++ Enum.map(right, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end))
    |> Enum.reverse()
    |> Enum.uniq_by(fn {k, _} -> String.downcase(k) end)
    |> Enum.reverse()
  end

  defp connection_error(method, url, reason),
    do: %Error{
      message: "#{method} #{url} failed: #{Exception.format_banner(:error, reason)}",
      kind: :connection
    }
end

defmodule Fountain.HTTP.Finch do
  @moduledoc false

  @finch FountainSdk.Finch

  def request(method, url, headers, body, timeout) do
    request = Finch.build(method_atom(method), url, headers, body)
    request_ref = Finch.async_request(request, @finch, request_options(timeout))

    try do
      receive_response(request_ref, deadline(timeout), nil, [], [])
    rescue
      error ->
        Finch.cancel_async_request(request_ref)
        {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  def stream(method, url, headers, timeout, on_chunk) do
    request = Finch.build(method_atom(method), url, headers)
    accumulator = %{status: nil, headers: [], body: []}

    case Finch.stream_while(
           request,
           @finch,
           accumulator,
           &stream_chunk(&1, &2, on_chunk),
           request_options(timeout)
         ) do
      {:ok, %{status: status, headers: response_headers, body: body}} ->
        response_body =
          if status in 200..299,
            do: nil,
            else: body |> Enum.reverse() |> IO.iodata_to_binary()

        {:ok, status, response_headers, response_body}

      {:error, reason, _accumulator} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp receive_response(request_ref, deadline, status, headers, body) do
    receive do
      {^request_ref, {:status, response_status}} ->
        receive_response(request_ref, deadline, response_status, headers, body)

      {^request_ref, {:headers, response_headers}} ->
        receive_response(request_ref, deadline, status, headers ++ response_headers, body)

      {^request_ref, {:data, chunk}} ->
        receive_response(request_ref, deadline, status, headers, [chunk | body])

      {^request_ref, :done} ->
        {:ok, status, headers, body |> Enum.reverse() |> IO.iodata_to_binary()}

      {^request_ref, {:error, reason}} ->
        {:error, reason}
    after
      remaining(deadline) ->
        Finch.cancel_async_request(request_ref)
        {:error, :timeout}
    end
  end

  defp stream_chunk({:status, status}, accumulator, _on_chunk),
    do: {:cont, %{accumulator | status: status}}

  defp stream_chunk({:headers, headers}, accumulator, _on_chunk),
    do: {:cont, %{accumulator | headers: accumulator.headers ++ headers}}

  defp stream_chunk({:trailers, headers}, accumulator, _on_chunk),
    do: {:cont, %{accumulator | headers: accumulator.headers ++ headers}}

  defp stream_chunk({:data, chunk}, %{status: status} = accumulator, on_chunk)
       when status in 200..299 do
    on_chunk.(chunk)
    {:cont, accumulator}
  end

  defp stream_chunk({:data, chunk}, accumulator, _on_chunk),
    do: {:cont, %{accumulator | body: [chunk | accumulator.body]}}

  defp request_options(:infinity), do: [receive_timeout: :infinity, request_timeout: :infinity]

  defp request_options(timeout),
    do: [pool_timeout: timeout, receive_timeout: timeout, request_timeout: timeout]

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp method_atom("GET"), do: :get
  defp method_atom("POST"), do: :post
  defp method_atom("PUT"), do: :put
  defp method_atom("PATCH"), do: :patch
  defp method_atom("DELETE"), do: :delete
  defp method_atom("HEAD"), do: :head
end
