defmodule RemoteBroker.StoreTest do
  use ExUnit.Case, async: false
  alias RemoteBroker.Store

  setup do
    for {key, value} <- [
          control_url: "https://home.example",
          token: String.duplicate("x", 48),
          request_options: [plug: {Req.Test, __MODULE__}]
        ] do
      Application.put_env(:remote_broker, key, value)
    end

    :ok
  end

  test "lookup carries no credentials and always enables per-request authorization" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/internal/broker/v1/lookup"

      Req.Test.json(conn, %{
        authorization: "session-id",
        expires_at: "2099-01-01T00:00:00Z",
        policy: "deny",
        patterns: ["api.example.com"],
        receipt: "signed-receipt"
      })
    end)

    assert {:ok, session} = Store.lookup("proxy-token")
    assert session.authorization == "session-id"
    assert session.rules |> Enum.all?(&is_nil(&1.credential))
    assert session.unmatched_host_policy == :deny
  end

  test "authorization never falls back on transport failure, bad responses or denial" do
    request = %{
      host: "api.example.com",
      port: 443,
      target: "/secret",
      method: "GET",
      scheme: :https
    }

    for status <- [401, 403, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "{}") end)
      expected = if status == 403, do: :denied, else: :unavailable
      assert Store.authorize("session-id", request) == {:error, expected}
    end

    Req.Test.stub(__MODULE__, fn _ -> raise "network failure" end)
    assert Store.authorize("session-id", request) == {:error, :unavailable}

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{rules: [%{scheme: "unknown"}]}) end)

    assert Store.authorize("session-id", request) == {:error, :unavailable}
  end

  test "every admission calls home without sending sensitive request targets" do
    request = %{
      host: "api.example.com",
      port: 443,
      target: "/secret?key=value",
      method: "GET",
      scheme: :https
    }

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute body =~ "secret"
      refute body =~ "value"

      assert Jason.decode!(body) == %{
               "authorization" => "session-id",
               "host" => "api.example.com",
               "port" => 443
             }

      Req.Test.json(conn, %{
        rules: [
          %{
            name: "test",
            pattern: "api.example.com",
            scheme: "basic",
            credential: %{basic: ["user", "password"]}
          }
        ]
      })
    end)

    assert {:ok, [rule]} = Store.authorize("session-id", request)
    assert rule.credential == {"user", "password"}
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "{}") end)
    assert Store.authorize("session-id", request) == {:error, :denied}
  end
end
