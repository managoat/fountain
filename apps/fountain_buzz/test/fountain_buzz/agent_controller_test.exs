defmodule FountainBuzz.AgentControllerTest do
  # Every provision request calls Manager.start_harness/1 under the global
  # Horde supervisor, even when start_harness_link/2 later rejects the launch.
  use FountainWeb.ConnCase, async: false
  import FountainBuzz.Factory

  alias Fountain.{Crypto, Vaults}

  setup do
    user = insert_verified_user()
    {_rec, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)

    on_exit(fn -> FountainBuzz.TestSupport.stop_all_harnesses!() end)

    %{user: user, raw_key: raw_key, agent: agent}
  end

  defp params(agent) do
    %{
      "name" => "philo",
      "relay_url" => "wss://relay.example",
      "agent_id" => agent.id,
      "pubkey" => String.duplicate("a", 64),
      "private_key_nsec" => "nsec1secret",
      "auth_tag" => ~s(["auth","owner"])
    }
  end

  test "POST provisions a hosted Buzz agent and never returns the nsec", %{
    conn: conn,
    user: user,
    raw_key: raw_key,
    agent: agent
  } do
    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", params(agent))

    data = json_response(conn, 201)["data"]
    assert data["name"] == "philo"
    assert data["enabled"] == true
    assert data["agent_id"] == agent.id
    refute json_response(conn, 201) |> inspect() =~ "nsec1secret"

    # The key landed in the vault, server-side.
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    vault = Vaults.get_vault(data["vault_id"], user.id)
    assert Vaults.decrypted_env(vault, dek)["BUZZ_PRIVATE_KEY"] == "nsec1secret"
  end

  test "POST is idempotent on the pubkey (converge)", %{
    conn: conn,
    raw_key: raw_key,
    agent: agent
  } do
    first =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", params(agent))
      |> json_response(201)

    second =
      build_conn()
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", params(agent))
      |> json_response(201)

    assert first["data"]["id"] == second["data"]["id"]
  end

  test "GET lists the tenant's Buzz agents", %{conn: conn, raw_key: raw_key, agent: agent} do
    build_conn()
    |> authed_with_key(raw_key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/buzz/agents", params(agent))

    data = conn |> authed_with_key(raw_key) |> get("/api/buzz/agents") |> json_response(200)
    assert Enum.any?(data["data"], &(&1["name"] == "philo"))
  end

  test "DELETE tears it down (identity and vault gone)", %{
    conn: conn,
    user: user,
    raw_key: raw_key,
    agent: agent
  } do
    created =
      build_conn()
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", params(agent))
      |> json_response(201)

    id = created["data"]["id"]
    vault_id = created["data"]["vault_id"]

    conn |> authed_with_key(raw_key) |> delete("/api/buzz/agents/#{id}") |> response(204)

    assert FountainBuzz.get_identity(id, user.id) == nil
    assert Vaults.get_vault(vault_id, user.id) == nil
  end

  # #783: an identity may name the environment its conversations launch under.
  test "POST stores an environment override and echoes it", %{
    conn: conn,
    user: user,
    raw_key: raw_key,
    agent: agent
  } do
    env = insert_env(user_id: user.id)

    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", Map.put(params(agent), "environment_id", env.id))

    assert json_response(conn, 201)["data"]["environment_id"] == env.id
  end

  test "POST stores a sandbox_mode and returns it", %{
    conn: conn,
    raw_key: raw_key,
    agent: agent
  } do
    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", Map.put(params(agent), "sandbox_mode", "persistent"))

    assert json_response(conn, 201)["data"]["sandbox_mode"] == "persistent"
  end

  # The OpenAPI cast refuses the enum before the context sees it, the same way
  # a bad respond_to is refused; the context's own check (buzz_test) covers a
  # caller that reaches provision_identity another way.
  test "POST with an unknown sandbox_mode is a 422 that names the field", %{
    conn: conn,
    raw_key: raw_key,
    agent: agent
  } do
    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", Map.put(params(agent), "sandbox_mode", "forever"))

    assert inspect(json_response(conn, 422)) =~ "sandbox_mode"
  end

  test "POST with a foreign environment_id is a 404, and nothing is provisioned", %{
    conn: conn,
    raw_key: raw_key,
    agent: agent
  } do
    foreign = insert_env(user_id: insert_verified_user().id)

    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", Map.put(params(agent), "environment_id", foreign.id))

    assert json_response(conn, 404)["error"] == "environment_not_found"
    assert FountainBuzz.list_identities(agent.user_id) == []
  end

  # #790: the provider passes the desktop's author gate through; it is stored,
  # echoed, and an omission on re-provision means owner-only.
  test "POST stores the author gate and echoes it", %{conn: conn, raw_key: raw_key, agent: agent} do
    pk = String.duplicate("b", 64)

    data =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/buzz/agents",
        Map.merge(params(agent), %{
          "respond_to" => "allowlist",
          "respond_to_allowlist" => [pk]
        })
      )
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["respond_to"] == "allowlist"
    assert data["respond_to_allowlist"] == [pk]

    again =
      build_conn()
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", params(agent))
      |> json_response(201)
      |> Map.fetch!("data")

    assert again["id"] == data["id"]
    assert again["respond_to"] == "owner-only"
    assert again["respond_to_allowlist"] == []
  end

  test "POST with allowlist mode and no pubkeys is a 422 naming the field", %{
    conn: conn,
    raw_key: raw_key,
    agent: agent
  } do
    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", Map.put(params(agent), "respond_to", "allowlist"))

    assert %{"errors" => %{"respond_to_allowlist" => [_]}} = json_response(conn, 422)
  end

  # #790: the operator's knob when the desktop cannot resend the policy.
  test "PATCH changes the author gate and echoes it; foreign ids are 404", %{
    conn: conn,
    raw_key: raw_key,
    agent: agent
  } do
    id =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", params(agent))
      |> json_response(201)
      |> get_in(["data", "id"])

    data =
      build_conn()
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> patch("/api/buzz/agents/#{id}", %{"respond_to" => "anyone"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == id
    assert data["respond_to"] == "anyone"

    assert %{"error" => _} =
             build_conn()
             |> authed_with_key(raw_key)
             |> put_req_header("content-type", "application/json")
             |> patch("/api/buzz/agents/#{id}", %{})
             |> json_response(422)

    assert %{"errors" => %{"respond_to_allowlist" => [_]}} =
             build_conn()
             |> authed_with_key(raw_key)
             |> put_req_header("content-type", "application/json")
             |> patch("/api/buzz/agents/#{id}", %{"respond_to" => "allowlist"})
             |> json_response(422)

    other = insert_verified_user()
    {_rec, other_key} = insert_api_key(other)

    assert build_conn()
           |> authed_with_key(other_key)
           |> put_req_header("content-type", "application/json")
           |> patch("/api/buzz/agents/#{id}", %{"respond_to" => "anyone"})
           |> json_response(404)
  end

  test "missing required fields is a 422", %{conn: conn, raw_key: raw_key, agent: agent} do
    bad = Map.delete(params(agent), "private_key_nsec")

    conn =
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/buzz/agents", bad)

    # OpenApiSpex CastAndValidate rejects the missing required field before the action.
    assert conn.status in [422, 400]
  end

  describe "the standing-cost gates (#1017)" do
    test "402 identity_limit_reached at the ceiling, with the numbers", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      prev = Application.get_env(:fountain_buzz, :buzz_identity_ceiling)
      Application.put_env(:fountain_buzz, :buzz_identity_ceiling, 1)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:fountain_buzz, :buzz_identity_ceiling, prev),
          else: Application.delete_env(:fountain_buzz, :buzz_identity_ceiling)
      end)

      {:ok, _} = FountainBuzz.provision_identity(user.id, params(agent))

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/buzz/agents", %{params(agent) | "pubkey" => String.duplicate("b", 64)})

      # 402 rather than 429: the fix is a ceiling change, not a retry.
      assert %{"error" => "identity_limit_reached", "count" => 1, "limit" => 1} =
               json_response(conn, 402)
    end

    test "402 insufficient_credits when the balance is exhausted", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      case Fountain.Credits.balance(user.id) do
        0 -> :ok
        c -> {:ok, _} = Fountain.Credits.debit(user.id, c, "burn_turn", idempotency_key: "d")
      end

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post("/api/buzz/agents", params(agent))

      # The FallbackController's 402, the same one every other spending door
      # gives, carrying `upgrade_url` — not the generic 422 the catch-all
      # would have produced.
      assert %{"error" => "insufficient_credits"} = json_response(conn, 402)
      assert FountainBuzz.list_identities(user.id) == []
    end
  end
end
