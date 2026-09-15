defmodule FountainWeb.EnvironmentPolicyRoundtripTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Agents

  test "API, versions and apply round-trip the existing null/empty/finite contract", %{conn: conn} do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    conn = authed_with_key(conn, raw_key)
    env = insert_env(user_id: user.id)

    modes = [
      {nil, "all_tenant_environments"},
      {[], "allowlist"},
      {[env.id], "allowlist"}
    ]

    for {ids, mode} <- modes do
      payload = %{
        "name" => "environment-policy-#{System.unique_integer([:positive])}",
        "model" => "anthropic/claude-sonnet-4-6",
        "runtime" => "claude",
        "allowed_environment_ids" => ids
      }

      created = conn |> post_json(~p"/api/agents", payload) |> json_response(201)
      id = created["data"]["id"]
      assert created["data"]["allowed_environment_ids"] == ids
      refute Map.has_key?(created["data"], "environment_access")
      assert Agents.get_agent(id, user.id).environment_access == mode

      read = conn |> get(~p"/api/agents/#{id}") |> json_response(200)
      assert read["data"]["allowed_environment_ids"] == ids
      updated = conn |> put_json(~p"/api/agents/#{id}", read["data"]) |> json_response(200)
      assert updated["data"]["allowed_environment_ids"] == ids

      version = conn |> get(~p"/api/agents/#{id}/versions/1") |> json_response(200)
      assert Map.fetch!(version["data"]["config"], "allowed_environment_ids") == ids
      refute Map.has_key?(version["data"], "environment_access")

      # Force a policy change first, so apply must restore the serialized shape.
      {:ok, _} =
        Agents.update_agent(Agents.get_agent(id, user.id), %{"allowed_environment_ids" => []})

      manifest = %{
        "resources" => [%{"kind" => "Agent", "name" => payload["name"], "spec" => payload}]
      }

      applied = conn |> post_json(~p"/api/apply", manifest) |> json_response(200)
      assert [%{"action" => action}] = applied["data"]["results"]
      assert action in ["updated", "unchanged"]

      assert %{environment_access: ^mode, allowed_environment_ids: ^ids} =
               Agents.get_agent(id, user.id)
    end
  end

  test "omitted API/apply policy preserves deny-all; explicit null opens only the tenant policy",
       %{conn: conn} do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    conn = authed_with_key(conn, raw_key)
    agent = insert_agent(user_id: user.id, allowed_environment_ids: [])

    conn
    |> put_json(~p"/api/agents/#{agent.id}", %{"description" => "API edit"})
    |> json_response(200)

    assert Agents.get_agent(agent.id, user.id).allowed_environment_ids == []

    manifest = %{
      "resources" => [
        %{"kind" => "Agent", "name" => agent.name, "spec" => %{"description" => "apply edit"}}
      ]
    }

    conn |> post_json(~p"/api/apply", manifest) |> json_response(200)
    assert Agents.get_agent(agent.id, user.id).allowed_environment_ids == []

    conn
    |> put_json(~p"/api/agents/#{agent.id}", %{"allowed_environment_ids" => nil})
    |> json_response(200)

    assert Agents.get_agent(agent.id, user.id).environment_access == "all_tenant_environments"
  end
end
