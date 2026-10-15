defmodule FountainWeb.ListCountsTest do
  @moduledoc """
  Usage counts in the resource read-model (#529).

  `list_agents_with_counts/2`, `list_environments_with_counts/1` and
  `list_vaults_with_counts/1` existed for the UI and had no controller caller,
  so an API consumer asking "is this environment in use / safe to delete" had
  to N+1 it client-side.
  """

  use FountainWeb.ConnCase, async: true

  setup do
    # `first/2` below takes the head of the list, and two agents inserted in
    # the same second are ordered by a random id — so the agent under test has
    # to be the only one.
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  defp first(conn, path) do
    conn |> get(path) |> json_response(200) |> Map.fetch!("data") |> hd()
  end

  describe "agents" do
    test "list and get both report conversation_count", %{conn: conn, user: user, key: key} do
      agent = insert_agent(user_id: user.id)
      insert_conversation(user_id: user.id, agent_id: agent.id)
      insert_conversation(user_id: user.id, agent_id: agent.id)

      conn = authed_with_key(conn, key)

      assert first(conn, "/api/agents")["conversation_count"] == 2

      # The single-resource read has to agree with the list; serving the
      # struct default here would report "no conversations" for a busy agent.
      assert conn
             |> get("/api/agents/#{agent.id}")
             |> json_response(200)
             |> get_in(["data", "conversation_count"]) == 2
    end

    test "a fresh agent reports zero, not null", %{conn: conn, user: user, key: key} do
      insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> first("/api/agents")
             |> Map.fetch!("conversation_count") == 0
    end

    test "another tenant's conversations do not count", %{conn: conn, user: user, key: key} do
      agent = insert_agent(user_id: user.id)
      other = insert_verified_user()
      insert_conversation(user_id: other.id, agent_id: agent.id)

      assert conn
             |> authed_with_key(key)
             |> first("/api/agents")
             |> Map.fetch!("conversation_count") == 0
    end

    test "creating an agent returns counts too", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/agents", %{
          "name" => "fresh",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude"
        })
        |> json_response(201)

      assert body["data"]["conversation_count"] == 0
    end
  end

  describe "environments" do
    setup %{user: user} do
      env = insert_env(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, _} = Fountain.Environments.upsert_secret(env, %{"key" => "A", "value" => "1"}, dek)
      insert_agent(user_id: user.id, environment_id: env.id)
      {:ok, env: env}
    end

    test "list reports secret_count and agent_count", %{conn: conn, key: key} do
      json = conn |> authed_with_key(key) |> first("/api/environments")

      assert json["secret_count"] == 1
      assert json["agent_count"] == 1
    end

    test "get agrees with list", %{conn: conn, key: key, env: env} do
      json =
        conn
        |> authed_with_key(key)
        |> get("/api/environments/#{env.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert json["secret_count"] == 1
      assert json["agent_count"] == 1
    end

    test "updating an environment still reports counts", %{conn: conn, key: key, env: env} do
      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/environments/#{env.id}", %{"name" => "renamed"})
        |> json_response(200)

      assert body["data"]["name"] == "renamed"
      assert body["data"]["secret_count"] == 1
      assert body["data"]["agent_count"] == 1
    end

    test "an unused environment reports agent_count 0 — the safe-to-delete answer", %{
      conn: conn,
      user: user,
      key: key
    } do
      unused = insert_env(user_id: user.id, name: "unused")

      json =
        conn
        |> authed_with_key(key)
        |> get("/api/environments/#{unused.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert json["agent_count"] == 0
      assert json["secret_count"] == 0
    end
  end

  describe "vaults" do
    test "list and get report secret_count", %{conn: conn, user: user, key: key} do
      vault = insert_vault(user_id: user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      {:ok, _} = Fountain.Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v"}, dek)

      conn = authed_with_key(conn, key)

      assert first(conn, "/api/vaults")["secret_count"] == 1

      assert conn
             |> get("/api/vaults/#{vault.id}")
             |> json_response(200)
             |> get_in(["data", "secret_count"]) == 1
    end

    test "an empty vault reports zero", %{conn: conn, user: user, key: key} do
      insert_vault(user_id: user.id)

      assert conn |> authed_with_key(key) |> first("/api/vaults") |> Map.fetch!("secret_count") ==
               0
    end
  end
end
