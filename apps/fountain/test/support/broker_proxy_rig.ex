defmodule Fountain.BrokerProxyRig do
  @moduledoc """
  A real proxy, a real origin and a sandbox-shaped client, for the handful
  of broker tests that have to see bytes rather than a synthesised
  telemetry event.

  `Fountain.Broker.Native`'s unit tests execute
  `[:managoat, :broker, :request]` themselves, which is the right shape for
  asserting what the handler does with an event. It cannot answer the other
  question ADR 0019 and #1501 ask: *does the library actually emit what we
  are relying on it to emit?* A row like "the query string never reaches
  `broker_requests.path`" is a claim about `managoat_broker`'s behaviour
  that Fountain stores the consequences of, and reading it out of a
  changelog is not a test.

  So this rig drives the real listener, with Fountain's own
  `Fountain.Broker.Native.Sessions` store and
  `Fountain.Broker.Native.attach_telemetry/0` handler, over a real
  `CONNECT` tunnel to a real TLS origin, and lets a test look at the row.

  Two things differ from production, both because the origin is local:
  `allow_private_upstreams: true` (the SSRF guard would refuse loopback)
  and `upstream_ssl_options` trusting the origin's throwaway CA. Neither
  touches the paths under test.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, start_supervised!: 2]

  alias Fountain.Broker
  alias Fountain.Broker.Native

  defmodule Origin do
    @moduledoc false
    # Echoes what it was actually sent, so a test can tell the difference
    # between "the proxy logged a path" and "the origin received a target".
    #
    # Two query parameters shape the answer, for the tests that need more than
    # an echo: `delay=<ms>` holds the response back, and `stream=1` sends it
    # as three chunks the way an SSE reply arrives. Every request is also
    # announced to the process that started the rig, so "the origin never saw
    # it" is an assertion rather than an absence.
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      case :persistent_term.get({Fountain.BrokerProxyRig, :observer}, nil) do
        nil -> :ok
        pid -> send(pid, {:origin_hit, conn.method, conn.request_path, Map.new(conn.req_headers)})
      end

      with %{"delay" => ms} <- conn.query_params, do: Process.sleep(String.to_integer(ms))

      echo =
        Jason.encode!(%{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_string,
          headers: Map.new(conn.req_headers),
          body: body
        })

      if conn.query_params["stream"] == "1" do
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        third = div(byte_size(echo), 3)

        ([binary_part(echo, 0, third), binary_part(echo, third, third)] ++
           [binary_part(echo, 2 * third, byte_size(echo) - 2 * third)])
        |> Enum.reduce(conn, fn part, conn ->
          {:ok, conn} = chunk(conn, part)
          conn
        end)
      else
        conn |> put_resp_content_type("application/json") |> send_resp(200, echo)
      end
    end
  end

  @doc """
  The whole rig: a TLS origin on loopback, the request-log writer, the
  telemetry handler and a listener on port 0 that trusts the origin.

  Returns `%{proxy_port:, origin_port:, origin_host:, log:}`. The process that
  calls this is sent `{:origin_hit, method, path, headers}` for every request
  the origin receives. The caller is
  responsible for `Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})`
  — the proxy answers on its own processes.
  """
  def start(opts \\ []) do
    {origin_ca, tls} = origin_tls()
    origin_port = start_https_origin(tls)

    observer = self()
    :persistent_term.put({__MODULE__, :observer}, observer)
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({__MODULE__, :observer}) end)

    log = start_supervised!(Fountain.Broker.Native.RequestLog)
    Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, self(), log)
    :ok = Native.attach_telemetry()
    watch_requests()

    {Managoat.Broker, listener_opts} = Native.listener_spec()

    start_supervised!(
      {Managoat.Broker,
       listener_opts
       |> Keyword.merge(
         port: 0,
         allow_private_upstreams: true,
         upstream_ssl_options: [cacerts: [X509.Certificate.to_der(origin_ca)]]
       )
       |> Keyword.merge(Keyword.take(opts, [:max_request_bytes, :request_read_timeout]))}
    )

    %{
      proxy_port: Managoat.Broker.port(),
      origin_port: origin_port,
      origin_host: "localhost:#{origin_port}",
      log: log
    }
  end

  @doc """
  Wait for the proxy's terminal event, flush the writer, and return the
  conversation's rows, newest first.

  The wait is the point. Since `managoat_broker` 0.3.0 the request event is
  **terminal**: it fires when the response body completes, and the library
  relays every byte to the client before showing it to the framer. So a test
  that has read its whole response has not necessarily seen the row yet, and
  flushing straight away finds an empty buffer perhaps one run in twenty.
  Waiting on the event rather than sleeping is what keeps this deterministic.
  """
  def rows(rig, conversation_id, expected \\ 1) do
    await_requests(conversation_id, expected)
    :ok = Fountain.Broker.Native.RequestLog.flush(rig.log)
    {:ok, %{events: events}} = Broker.request_log(conversation_id)
    events
  end

  # Telemetry handlers are global and other modules run beside this one, so
  # the handler forwards the conversation id and `await_requests/2` receives
  # selectively on it rather than counting every event on the node.
  defp watch_requests do
    id = "broker-rig-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      id,
      [:managoat, :broker, :request],
      fn _event, _measurements, meta, _config ->
        case Map.get(meta, :meta) do
          %{"conversation_id" => conv} when is_binary(conv) -> send(test, {:broker_request, conv})
          _ -> :ok
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  defp await_requests(_conversation_id, 0), do: :ok

  defp await_requests(conversation_id, n) do
    receive do
      {:broker_request, ^conversation_id} -> await_requests(conversation_id, n - 1)
    after
      5_000 -> raise "no broker request event for #{conversation_id} within 5s"
    end
  end

  @doc """
  A tunnel as a brokered sandbox opens one: `CONNECT` with the session's own
  proxy credential, then TLS trusting the broker CA. `authority` is the
  origin under another name (`"127.0.0.1:<port>"`), for a test that needs two
  destinations out of the one origin; an IP authority sends no SNI.
  """
  def tunnel(rig, session, authority \\ nil) do
    authority = authority || rig.origin_host
    [{"HTTPS_PROXY", url} | _] = Broker.sandbox_env(session)
    %URI{userinfo: userinfo} = URI.parse(url)

    {:ok, tcp} =
      :gen_tcp.connect(~c"127.0.0.1", rig.proxy_port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        tcp,
        "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n" <>
          "Proxy-Authorization: Basic #{Base.encode64(userinfo)}\r\n\r\n"
      )

    {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)

    unless reply =~ "HTTP/1.1 200" do
      raise "CONNECT #{authority} answered #{inspect(reply)}"
    end

    name =
      if String.starts_with?(authority, "localhost"),
        do: [
          server_name_indication: ~c"localhost",
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        else: [server_name_indication: :disable]

    {:ok, tls} =
      :ssl.connect(
        tcp,
        [verify: :verify_peer, cacerts: broker_ca_ders(), active: false] ++ name,
        5_000
      )

    tls
  end

  @doc "Send one origin-form request down the tunnel; returns the origin's decoded echo."
  def request(tls, raw) do
    :ok = :ssl.send(tls, raw)
    read_json(tls, "")
  end

  @doc """
  Send one origin-form request down the tunnel and return whatever came back,
  the proxy's own refusals included: `%{status:, headers:, body:}`, with the
  body de-chunked. `{:error, reason}` when the tunnel is gone.
  """
  def exchange(tls, raw) do
    with :ok <- :ssl.send(tls, raw), do: read_response(tls, "")
  end

  defp read_response(tls, acc) do
    case response(acc) do
      {:ok, response} ->
        response

      :more ->
        case :ssl.recv(tls, 0, 5_000) do
          {:ok, data} -> read_response(tls, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp response(acc) do
    with [head, rest] <- String.split(acc, "\r\n\r\n", parts: 2),
         [status_line | lines] = String.split(head, "\r\n"),
         [_, status] <- Regex.run(~r/\AHTTP\/1\.1 (\d{3})/, status_line) do
      headers =
        Map.new(lines, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end)

      body =
        cond do
          headers["transfer-encoding"] == "chunked" -> dechunk(rest, "")
          length = headers["content-length"] -> sized(rest, String.to_integer(length))
          true -> {:ok, rest}
        end

      with {:ok, body} <- body do
        {:ok, %{status: String.to_integer(status), headers: headers, body: body}}
      end
    else
      _ -> :more
    end
  end

  defp sized(rest, length) when byte_size(rest) >= length, do: {:ok, binary_part(rest, 0, length)}
  defp sized(_rest, _length), do: :more

  defp dechunk(rest, acc) do
    with [size, tail] <- String.split(rest, "\r\n", parts: 2),
         {size, ""} <- Integer.parse(size, 16) do
      cond do
        size == 0 ->
          {:ok, acc}

        byte_size(tail) >= size + 2 ->
          dechunk(
            binary_part(tail, size + 2, byte_size(tail) - size - 2),
            acc <> binary_part(tail, 0, size)
          )

        true ->
          :more
      end
    else
      _ -> :more
    end
  end

  @doc """
  One absolute-form plain request straight at the proxy, no tunnel. Returns
  the origin's decoded echo. The plain path only reaches a plain origin, so
  this takes an explicit `http://` target.
  """
  def plain_request(rig, session, target, host) do
    [{"HTTPS_PROXY", url} | _] = Broker.sandbox_env(session)
    %URI{userinfo: userinfo} = URI.parse(url)

    {:ok, tcp} =
      :gen_tcp.connect(~c"127.0.0.1", rig.proxy_port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        tcp,
        "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n" <>
          "Proxy-Authorization: Basic #{Base.encode64(userinfo)}\r\nConnection: close\r\n\r\n"
      )

    read_plain_json(tcp, "")
  end

  @doc "Start a plain HTTP origin on 127.0.0.1:0; returns its port."
  def start_http_origin do
    pid =
      start_supervised!(
        {Bandit, plug: Origin, scheme: :http, port: 0, ip: {127, 0, 0, 1}},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # ---------------------------------------------------------------------------

  defp broker_ca_ders do
    {:ok, pem} = Broker.ca_pem()
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
  end

  defp origin_tls do
    ca_key = X509.PrivateKey.new_ec(:secp256r1)
    ca = X509.Certificate.self_signed(ca_key, "/CN=Broker Rig Origin CA", template: :root_ca)
    key = X509.PrivateKey.new_ec(:secp256r1)

    sans =
      X509.Certificate.Extension.subject_alt_name(
        dNSName: "localhost",
        iPAddress: <<127, 0, 0, 1>>
      )

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=localhost", ca, ca_key, extensions: [subject_alt_name: sans])

    {ca, [cert: X509.Certificate.to_der(cert), key: {:ECPrivateKey, X509.PrivateKey.to_der(key)}]}
  end

  defp start_https_origin(tls) do
    pid =
      start_supervised!(
        {Bandit,
         plug: Origin,
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         thousand_island_options: [transport_options: tls]},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp read_json(tls, acc) do
    case framed(acc) do
      {:ok, body} -> Jason.decode!(body)
      :more -> with {:ok, data} <- :ssl.recv(tls, 0, 5_000), do: read_json(tls, acc <> data)
    end
  end

  defp read_plain_json(tcp, acc) do
    case framed(acc) do
      {:ok, body} ->
        Jason.decode!(body)

      :more ->
        with {:ok, data} <- :gen_tcp.recv(tcp, 0, 5_000), do: read_plain_json(tcp, acc <> data)
    end
  end

  defp framed(acc) do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, len] <- Regex.run(~r/content-length: (\d+)/i, head),
         len = String.to_integer(len),
         true <- byte_size(body) >= len do
      {:ok, binary_part(body, 0, len)}
    else
      _ -> :more
    end
  end
end
