defmodule RemoteBroker.LookupResponseTest do
  use ExUnit.Case, async: false

  setup do
    keys = [:control_url, :token, :request_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:remote_broker, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:remote_broker, key, value)
          :error -> Application.delete_env(:remote_broker, key)
        end
      end
    end)

    Application.put_env(:remote_broker, :token, "test-deployment-token")
    Application.delete_env(:remote_broker, :request_options)
    name = :"lookup_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Managoat.Broker,
       name: name, port: 0, ca_seed: :crypto.strong_rand_bytes(32), store: RemoteBroker.Store}
    )

    %{port: Managoat.Broker.port(name)}
  end

  for {control_status, proxy_status} <- [{403, 407}, {401, 503}, {503, 503}] do
    test "control #{control_status} becomes proxy #{proxy_status} on both HTTP paths", ctx do
      for line <- ["CONNECT example.invalid:443 HTTP/1.1", "GET http://example.invalid/ HTTP/1.1"] do
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, {_, port}} = :inet.sockname(listener)
        Application.put_env(:remote_broker, :control_url, "http://127.0.0.1:#{port}")

        server =
          Task.async(fn ->
            {:ok, socket} = :gen_tcp.accept(listener, 2_000)
            {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{unquote(control_status)} Refused\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
              )

            :gen_tcp.close(socket)
          end)

        {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false])
        auth = Base.encode64("test-session-token:label")

        :ok =
          :gen_tcp.send(
            client,
            line <> "\r\nHost: example.invalid\r\nProxy-Authorization: Basic #{auth}\r\n\r\n"
          )

        {:ok, response} = :gen_tcp.recv(client, 0, 5_000)
        assert response =~ "HTTP/1.1 #{unquote(proxy_status)}"

        assert String.contains?(String.downcase(response), "proxy-authenticate:") ==
                 (unquote(proxy_status) == 407)

        refute response =~ "test-session-token"

        if unquote(proxy_status) == 503,
          do: assert({:error, :closed} = :gen_tcp.recv(client, 0, 1_000))

        :gen_tcp.close(client)
        assert :ok = Task.await(server)
        :gen_tcp.close(listener)
      end
    end
  end
end
