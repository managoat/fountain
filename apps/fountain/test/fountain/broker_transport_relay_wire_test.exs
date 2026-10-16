defmodule Fountain.BrokerTransportRelayWireTest do
  # Owns the real broker and request-log writer, both named processes.
  use Fountain.DataCase, async: false

  alias Fountain.Broker
  alias Fountain.BrokerProxyRig, as: Rig

  @relay Path.expand("../../priv/broker/transport-relay.cjs", __DIR__)

  test "the TLS transport preserves broker authentication, policy, rotation and logging" do
    Fountain.BrokerTestHelpers.own_broker()
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    rig = Rig.start()
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    {:ok, session} = Broker.prepare(conv.id, %{}, %{}, user_id: user.id)
    port = start_relay(rig.proxy_port, conv.id)
    local = %{rig | proxy_port: port}

    for current <- [session, elem(Broker.prepare(conv.id, %{}, %{}, user_id: user.id), 1)] do
      socket = Rig.tunnel(local, current)
      report = Rig.request(socket, "GET /relay HTTP/1.1\r\nHost: #{rig.origin_host}\r\n\r\n")
      assert report["path"] == "/relay"
      :ssl.close(socket)
      assert [%{status: 200} | _] = Rig.rows(rig, conv.id)
    end

    http_port = Rig.start_http_origin()
    host = "localhost:#{http_port}"
    assert %{"path" => "/plain"} = Rig.plain_request(local, session, "http://#{host}/plain", host)
    assert [%{status: 200} | _] = Rig.rows(rig, conv.id)

    {:ok, denied} =
      Broker.prepare(conv.id, %{}, %{}, user_id: user.id, network: {:limited, []})

    assert connect_reply(port, denied, rig.origin_host) =~ "403"

    from(s in Fountain.Broker.Native.Session,
      where: s.token_hash == ^:crypto.hash(:sha256, session.token)
    )
    |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -60)])

    assert connect_reply(port, session, rig.origin_host) =~ "407"
    assert connect_reply(port, %{session | token: "invalid"}, rig.origin_host) =~ "407"
  end

  defp connect_reply(port, session, host) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
    auth = Base.encode64(session.token <> ":" <> session.vault)

    :ok =
      :gen_tcp.send(
        socket,
        "CONNECT #{host} HTTP/1.1\r\nProxy-Authorization: Basic #{auth}\r\n\r\n"
      )

    {:ok, reply} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    reply
  end

  defp start_relay(broker_port, owner) do
    directory = Fountain.TmpDir.mkdir!("broker-wire")
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      X509.Certificate.self_signed(key, "/CN=localhost",
        template: :root_ca,
        extensions: [
          subject_alt_name: X509.Certificate.Extension.subject_alt_name(dNSName: "localhost")
        ]
      )

    cert_path = Path.join(directory, "cert.pem")
    key_path = Path.join(directory, "key.pem")
    File.write!(cert_path, X509.Certificate.to_pem(cert))
    File.write!(key_path, X509.PrivateKey.to_pem(key))
    ingress = Path.expand("../support/broker_tls_ingress.cjs", __DIR__)
    executable = System.find_executable("node")

    server =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 1024},
        args: [ingress, to_string(broker_port), cert_path, key_path]
      ])

    ingress_port =
      receive do
        {^server, {:data, {:eol, port}}} -> String.to_integer(port)
      after
        5_000 -> flunk("TLS ingress did not start")
      end

    {:ok, reservation} = :gen_tcp.listen(0, [])
    {:ok, {_, listen}} = :inet.sockname(reservation)
    :gen_tcp.close(reservation)

    config =
      Jason.encode!(%{
        host: "localhost",
        port: ingress_port,
        listen: listen,
        owner: owner,
        ca: cert_path,
        controlDirectory: Path.join(directory, "control")
      })

    on_exit(fn ->
      System.cmd(executable, [@relay, "stop", config], stderr_to_stdout: true)
      if Port.info(server), do: Port.close(server)
    end)

    assert {_, 0} = System.cmd(executable, [@relay, "ensure", config], stderr_to_stdout: true)
    listen
  end
end
