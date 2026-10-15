defmodule FountainWeb.EndpointHTTP2Test do
  # Bandit's HTTP/2 stack is turned off (EEF-CVE-2026-105659, config.exs).
  # These tests start Bandit with the endpoint's own `http:` options and check
  # that an h2c prior-knowledge connection is refused while HTTP/1.1 is served.
  use ExUnit.Case, async: true

  @h2_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  defmodule OkPlug do
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  test "the endpoint's http config disables HTTP/2" do
    http = Application.fetch_env!(:fountain, FountainWeb.Endpoint)[:http]

    assert http[:http_2_options][:enabled] == false
  end

  test "an h2c prior-knowledge connection is closed and HTTP/1.1 is served" do
    port = start_bandit!()

    {:ok, h2} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(h2, @h2_preface)
    # An HTTP/2 server would answer the preface with a SETTINGS frame.
    assert {:error, :closed} = :gen_tcp.recv(h2, 0, 2_000)

    {:ok, h1} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(h1, "GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n")
    assert {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(h1, 0, 2_000)
  end

  defp start_bandit! do
    http = Application.fetch_env!(:fountain, FountainWeb.Endpoint)[:http]

    opts =
      http
      |> Keyword.drop([:ip, :port])
      |> Keyword.merge(plug: OkPlug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    pid = start_supervised!({Bandit, opts})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
