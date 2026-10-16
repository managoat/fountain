defmodule FountainWeb.Plugs.BrokerControlTest do
  use Fountain.DataCase, async: true
  import Plug.Test
  alias Fountain.Broker.Native
  alias Fountain.Broker.Native.{Sessions, Request, RequestLog}
  alias FountainWeb.Plugs.BrokerControl
  @token String.duplicate("x", 48)

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, session} =
      Native.prepare(conv.id, %{"GITHUB_TOKEN" => "secret-first"}, %{}, user_id: user.id)

    %{user: user, conv: conv, session: session}
  end

  defp request(action, body, token \\ @token) do
    conn(:post, "/internal/broker/v1/" <> action, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> BrokerControl.call(token: @token)
  end

  test "deployment authentication is required and disabled by default" do
    assert request("lookup", %{}, "wrong").status == 401
    conn = conn(:post, "/internal/broker/v1/lookup", "{}")
    assert BrokerControl.call(conn, token: nil).status == 401
    assert BrokerControl.call(conn(:get, "/api/auth/me"), []).halted == false
  end

  test "lookup exports patterns and a server binding, never credentials", %{session: session} do
    conn = request("lookup", %{token: session.token})
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    refute conn.resp_body =~ "secret-first"
    refute conn.resp_body =~ session.token
    body = Jason.decode!(conn.resp_body)

    assert body["patterns"] == [
             "api.github.com",
             "api.github.com",
             "api.githubcopilot.com",
             "api.githubcopilot.com",
             "github.com"
           ]

    assert request("lookup", %{token: "unknown"}).status == 403
  end

  test "each admission sees rotation and revocation and restricts credential delivery to the host",
       %{session: session, conv: conv, user: user} do
    body = request("lookup", %{token: session.token}).resp_body |> Jason.decode!()
    args = %{authorization: body["authorization"], host: "api.github.com", port: 443}
    assert request("authorize", args).resp_body =~ "secret-first"
    assert request("authorize", %{args | host: "example.com"}).resp_body == ~s({"rules":[]})

    assert {:ok, 1} =
             Native.refresh(conv.id, %{"GITHUB_TOKEN" => "secret-second"}, %{}, user_id: user.id)

    updated = request("authorize", args)
    assert updated.resp_body =~ "secret-second"
    refute updated.resp_body =~ "secret-first"
    :ok = Sessions.release_session(user.id, conv.id, session.token)
    assert request("authorize", args).status == 403
    assert request("lookup", %{token: session.token}).status == 403
  end

  test "custom templates export only referenced secrets and tokens stay session-bound", ctx do
    other_user = insert_verified_user()

    other_conv =
      insert_conversation(user_id: other_user.id, agent: insert_agent(user_id: other_user.id))

    {:ok, other} =
      Sessions.create(%{
        user_id: other_user.id,
        conversation_id: other_conv.id,
        ttl_seconds: 60,
        rules: [
          %Managoat.Broker.Rule{
            name: "custom",
            pattern: "custom.example",
            scheme: :custom,
            template: %{"x-key" => "{{ KEY }}"},
            credential: %{"KEY" => "needed", "UNRELATED" => "never-export"}
          }
        ]
      })

    first = request("lookup", %{token: ctx.session.token}).resp_body |> Jason.decode!()
    second = request("lookup", %{token: other.token}).resp_body |> Jason.decode!()
    refute first["authorization"] == second["authorization"]
    args = %{authorization: second["authorization"], host: "custom.example", port: 443}
    reply = request("authorize", args)
    assert reply.resp_body =~ "needed"
    refute reply.resp_body =~ "never-export"

    assert request("authorize", %{args | authorization: first["authorization"]}).resp_body ==
             ~s({"rules":[]})
  end

  test "expired and malformed authorizations are refused", %{session: session} do
    body = request("lookup", %{token: session.token}).resp_body |> Jason.decode!()
    args = %{authorization: body["authorization"], host: "api.github.com", port: 443}

    Repo.update_all(Fountain.Broker.Native.Session,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert request("authorize", args).status == 403
    assert request("authorize", %{args | authorization: "invalid"}).status == 403
    assert request("authorize", %{args | port: 0}).status == 400
  end

  test "terminal events keep the signed tenant binding after revocation and redact targets",
       %{session: session, conv: conv, user: user} do
    body = request("lookup", %{token: session.token}).resp_body |> Jason.decode!()
    :ok = Sessions.release(conv.id)

    event = %{
      receipt: body["receipt"],
      method: "GET",
      host: "api.github.com",
      outcome: "injected",
      service: "github-api",
      status: 200,
      latency_ms: 12,
      user_id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      path: "/secret-target",
      error: "secret-error"
    }

    writer = start_supervised!({RequestLog, name: nil})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), writer)
    # Capture only this test's context-authenticated row; no global writer state.
    Mimic.stub(RequestLog, :record, fn row -> RequestLog.record(row, writer) end)
    assert request("events", %{events: [event]}).status == 200
    RequestLog.flush(writer)
    row = Repo.one!(Request)
    assert row.user_id == user.id
    assert row.conversation_id == conv.id
    assert row.path == "/[REDACTED]"
    assert row.error == nil
    assert row.credential_keys == ["GITHUB_TOKEN"]
    assert request("events", %{events: [%{event | receipt: "forged"}]}).status == 200
    RequestLog.flush(writer)
    assert Repo.aggregate(Request, :count) == 1
  end
end
