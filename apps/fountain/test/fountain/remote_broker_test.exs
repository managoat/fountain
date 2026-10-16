# Exercise the standalone release's real store against the real home protocol.
# It is deliberately not a Fountain production dependency.
for file <- ~w(control store) do
  Code.require_file(Path.expand("../../../../broker/lib/remote_broker/#{file}.ex", __DIR__))
end

defmodule Fountain.RemoteBrokerTest do
  # Owns the named proxy listener, test transport config and shared SQL sandbox.
  use Fountain.DataCase, async: false
  import Fountain.BrokerTestHelpers
  alias Fountain.Broker.Native.Sessions
  alias Fountain.BrokerProxyRig, as: Rig
  alias Managoat.Broker.Rule

  setup do
    own_broker()
    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
    previous = Application.get_all_env(:remote_broker)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:remote_broker),
          do: Application.delete_env(:remote_broker, key)

      for {key, value} <- previous, do: Application.put_env(:remote_broker, key, value)
    end)

    token = String.duplicate("t", 48)
    Application.put_env(:remote_broker, :control_url, "https://home.example")
    Application.put_env(:remote_broker, :token, token)

    Application.put_env(:remote_broker, :request_options,
      plug: fn conn -> FountainWeb.Plugs.BrokerControl.call(conn, token: token) end
    )

    rig = Rig.start(store: RemoteBroker.Store)
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, session} =
      Sessions.create(%{
        user_id: user.id,
        conversation_id: conv.id,
        ttl_seconds: 60,
        unmatched_host_policy: :deny,
        meta: %{
          "user_id" => user.id,
          "conversation_id" => conv.id,
          "credential_keys" => %{"example" => ["KEY"]}
        },
        rules: [
          %Rule{
            name: "example",
            pattern: rig.origin_host,
            scheme: :bearer,
            credential: "first-secret"
          }
        ]
      })

    %{rig: rig, session: session, user: user, conv: conv}
  end

  test "existing CONNECT admits with fresh credentials, then refuses after revocation", ctx do
    tls = Rig.tunnel(ctx.rig, ctx.session)
    on_exit(fn -> :ssl.close(tls) end)
    raw = "GET /stream?stream=1 HTTP/1.1\r\nHost: #{ctx.rig.origin_host}\r\n\r\n"
    first = Rig.exchange(tls, raw)
    assert first.status == 200

    assert Jason.decode!(first.body)["headers"]["authorization_sha256"] ==
             Rig.digest("Bearer first-secret")

    assert_receive {:origin_hit, "GET", "/stream", _}

    {:ok, 1} =
      Sessions.update_rules(
        ctx.conv.id,
        ctx.user.id,
        [
          %Rule{
            name: "example",
            pattern: ctx.rig.origin_host,
            scheme: :bearer,
            credential: "rotated-secret"
          }
        ],
        %{}
      )

    second = Rig.exchange(tls, raw)
    assert second.status == 200

    assert Jason.decode!(second.body)["headers"]["authorization_sha256"] ==
             Rig.digest("Bearer rotated-secret")

    assert_receive {:origin_hit, "GET", "/stream", _}
    :ok = Sessions.release(ctx.conv.id)
    assert Rig.exchange(tls, raw).status == 403
    refute_receive {:origin_hit, _, _, _}, 50
  end

  test "home outage refuses requests even on an authenticated tunnel", ctx do
    tls = Rig.tunnel(ctx.rig, ctx.session)
    on_exit(fn -> :ssl.close(tls) end)

    Application.put_env(:remote_broker, :request_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 503, "{}") end
    )

    response = Rig.exchange(tls, "GET / HTTP/1.1\r\nHost: #{ctx.rig.origin_host}\r\n\r\n")
    assert response.status == 503
    refute_receive {:origin_hit, _, _, _}, 50
  end
end
