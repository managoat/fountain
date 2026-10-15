defmodule FountainWeb.AgentVersionControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Agents

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, system: "be helpful")
    {:ok, _} = Agents.update_agent(agent, %{"system" => "be terse"})
    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  describe "GET /api/agents/:id/versions" do
    test "lists the agent's versions newest first, with full config", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}/versions")

      body = json_response(conn, 200)
      assert [%{"version" => 2} = v2, %{"version" => 1} = v1] = body["data"]
      assert v2["agent_id"] == agent.id
      assert v2["config"]["system"] == "be terse"
      assert v1["config"]["system"] == "be helpful"
      assert is_binary(v2["id"]) and is_binary(v2["inserted_at"])
    end

    test "404s on another tenant's agent", %{conn: conn, raw_key: raw_key} do
      other = insert_verified_user()
      other_agent = insert_agent(user_id: other.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{other_agent.id}/versions")

      assert json_response(conn, 404)
    end

    test "401s without authentication", %{conn: conn, agent: agent} do
      assert conn |> get("/api/agents/#{agent.id}/versions") |> json_response(401)
    end
  end

  describe "GET /api/agents/:id/versions/:version" do
    test "returns one version by number", %{conn: conn, raw_key: raw_key, agent: agent} do
      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}/versions/1")

      body = json_response(conn, 200)
      assert body["data"]["version"] == 1
      assert body["data"]["config"]["system"] == "be helpful"
    end

    test "404s on a version the agent never had", %{conn: conn, raw_key: raw_key, agent: agent} do
      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}/versions/9")

      assert json_response(conn, 404)
    end

    # The path parameter is typed integer in the spec, so OpenApiSpex refuses
    # a non-number before the action runs (422, like every other cast error).
    test "422s on a version that is not a number", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}/versions/latest")

      assert json_response(conn, 422)
    end

    test "404s on another tenant's agent", %{conn: conn, raw_key: raw_key} do
      other = insert_verified_user()
      other_agent = insert_agent(user_id: other.id)

      conn =
        conn |> authed_with_key(raw_key) |> get("/api/agents/#{other_agent.id}/versions/1")

      assert json_response(conn, 404)
    end
  end

  # There is no rollback endpoint. The way back to a version is to read it and
  # write its config to the agent again, which becomes the newest version.
  describe "going back to a version" do
    test "PUT with an old version's config restores it as a new version", %{
      conn: conn,
      raw_key: raw_key,
      user: user,
      agent: agent
    } do
      old =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/agents/#{agent.id}/versions/1")
        |> json_response(200)

      body =
        build_conn()
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> put("/api/agents/#{agent.id}", Jason.encode!(old["data"]["config"]))
        |> json_response(200)

      assert body["data"]["system"] == "be helpful"
      assert [v3, v2, v1] = Agents.list_agent_versions(agent.id, user.id)
      assert v3.version == 3
      assert v3.config == v1.config
      assert v2.config["system"] == "be terse"
    end
  end
end
