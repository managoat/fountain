defmodule FountainWeb.ConversationEgressTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Broker

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")
    conv = insert_conversation(user_id: user.id)

    previous =
      for k <- [:broker_listen_port, :broker_proxy_url],
          do: {k, Application.get_env(:fountain, k)}

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(is_nil(v),
              do: Application.delete_env(:fountain, k),
              else: Application.put_env(:fountain, k, v)
            )
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user, conv: conv}
  end

  test "another tenant's conversation is not found", %{conn: conn} do
    other = insert_conversation(user_id: insert_verified_user().id)
    reject(Broker, :request_log, 2)
    assert conn |> get("/api/conversations/#{other.id}/egress") |> json_response(404)
  end

  test "an unbrokered account gets an empty page that says so", %{conn: conn, conv: conv} do
    Application.delete_env(:fountain, :broker_listen_port)
    reject(Broker, :request_log, 2)

    assert %{"data" => [], "brokered" => false} =
             conn |> get("/api/conversations/#{conv.id}/egress") |> json_response(200)
  end

  test "a brokered conversation gets the broker's rows and a cursor", %{conn: conn, conv: conv} do
    expect(Broker, :request_log, fn id, opts ->
      assert id == conv.id
      assert opts == [limit: 2, before: 9]

      {:ok,
       %{
         events: [
           %{
             id: 8,
             at: ~U[2026-08-25 10:00:00Z],
             method: "GET",
             host: "api.github.com:443",
             path: "/user",
             service: "github-api",
             credential_keys: ["GITHUB_TOKEN"],
             status: 200,
             latency_ms: 120,
             error: nil
           }
         ],
         next: 6
       }}
    end)

    assert %{"data" => [row], "next" => 6, "brokered" => true} =
             conn
             |> get("/api/conversations/#{conv.id}/egress?limit=2&before=9")
             |> json_response(200)

    assert %{
             "host" => "api.github.com:443",
             "service" => "github-api",
             "credential_keys" => ["GITHUB_TOKEN"],
             "status" => 200
           } = row
  end

  test "a broker that does not answer is a 502 with a sentence, not an inspected term",
       %{conn: conn, conv: conv} do
    expect(Broker, :request_log, fn _id, _opts ->
      {:error, {:broker, :request_log, :not_configured}}
    end)

    assert %{
             "error" => "broker_unavailable",
             "message" => "The egress broker did not answer.",
             "reason" => "not_configured"
           } = conn |> get("/api/conversations/#{conv.id}/egress") |> json_response(502)
  end

  # The log names which secrets went to which host: a sandbox's own token
  # must not be able to read it, for its conversation or any other (#1152).
  test "a sprite-scoped token cannot read the egress log", %{conn: conn, user: user, conv: conv} do
    {_rec, sprite_key} = insert_sprite_api_key(user)
    reject(Broker, :request_log, 2)

    body =
      conn
      |> authed_with_key(sprite_key)
      |> get("/api/conversations/#{conv.id}/egress")
      |> json_response(403)

    assert body["reason"] == "insufficient_scope"
  end
end
