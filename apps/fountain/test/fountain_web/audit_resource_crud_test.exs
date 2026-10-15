defmodule FountainWeb.AuditResourceCrudTest do
  @moduledoc """
  Resource CRUD leaves a trail whichever door it came through (#543).

  Before this, every agent/environment/vault mutation was audited when driven
  through `/api` — the blanket plug on that pipeline caught it — and silent
  when driven through the UI. That is the exact inverse of the secrets gap
  `FountainWeb.Audited` documents as previously fixed, and it meant the
  browser, where most of these mutations actually happen, was the one surface
  with no record.

  The fix records inside the context function, so these tests come in two
  halves: the context half proves each mutation audits at all, and the surface
  half proves each door passes its own attribution down. The console's own
  door for these closed with ADR 0076; the API is the one left.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.{Agents, Audit, Environments, Vaults}

  defp events_for(user_id), do: Audit.list_recent_for_user(user_id, 200)

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  defp actions_for(user_id), do: Enum.map(events_for(user_id), & &1.action)

  describe "the context audits every resource mutation" do
    setup do
      {:ok, user: insert_verified_user()}
    end

    test "agent create, update and delete", %{user: user} do
      {:ok, agent} = Agents.create_agent(agent_attrs(%{"user_id" => user.id}))

      created = find_action(user.id, "agent.created")
      assert created.resource_type == "agent"
      assert created.resource_id == agent.id
      assert created.metadata["name"] == agent.name
      # No caller said who they were, so the trail says the account itself —
      # never a guess at a surface that was not involved.
      assert created.actor == "self"

      {:ok, _} = Agents.update_agent(agent, %{"model" => "anthropic/claude-opus-4-5"})
      assert find_action(user.id, "agent.updated").metadata["changed"] == ["model"]

      {:ok, _} = Agents.delete_agent(agent)
      assert find_action(user.id, "agent.deleted").resource_id == agent.id
    end

    test "environment create, update and delete", %{user: user} do
      {:ok, env} = Environments.create_environment(env_attrs(%{"user_id" => user.id}))
      assert find_action(user.id, "environment.created").resource_id == env.id

      {:ok, _} = Environments.update_environment(env, %{"setup_script" => "apt-get update"})
      assert find_action(user.id, "environment.updated").metadata["changed"] == ["setup_script"]

      {:ok, _} = Environments.delete_environment(env)
      assert find_action(user.id, "environment.deleted").resource_id == env.id
    end

    test "vault create, update and delete", %{user: user} do
      {:ok, vault} = Vaults.create_vault(vault_attrs(%{"user_id" => user.id}))
      assert find_action(user.id, "vault.created").resource_id == vault.id

      {:ok, _} = Vaults.update_vault(vault, %{"description" => "prod overrides"})
      assert find_action(user.id, "vault.updated").metadata["changed"] == ["description"]

      {:ok, _} = Vaults.delete_vault(vault)
      assert find_action(user.id, "vault.deleted").resource_id == vault.id
    end

    test "avatar set and remove", %{user: user} do
      agent = insert_agent(user_id: user.id)
      png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

      {:ok, _} = Agents.upload_avatar(agent, png, "image/png")
      set = find_action(user.id, "agent.avatar.set")
      assert set.resource_id == agent.id
      assert set.metadata["media_type"] == "image/png"

      {:ok, _} = Agents.delete_avatar(agent)
      assert find_action(user.id, "agent.avatar.removed").resource_id == agent.id
    end

    test "a rejected changeset records nothing", %{user: user} do
      # The mutation did not happen, so the trail must not claim it did.
      {:error, _} = Agents.create_agent(agent_attrs(%{"user_id" => user.id, "name" => ""}))

      refute "agent.created" in actions_for(user.id)
    end

    test "an update records which fields moved, never their values", %{user: user} do
      env = insert_env(user_id: user.id)

      {:ok, _} =
        Environments.update_environment(env, %{"setup_script" => "curl secret.example/install"})

      event = find_action(user.id, "environment.updated")
      assert event.metadata["changed"] == ["setup_script"]

      # Guard the guard (#406): if the update stopped auditing, the refute
      # below would pass over nothing.
      assert event
      refute inspect(event) =~ "secret.example"
    end
  end

  describe "the API surface" do
    test "a create through /api records the semantic event alongside the plug's request log",
         %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/agents", %{
        name: "from-the-api",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude"
      })
      |> json_response(201)

      semantic = find_action(user.id, "agent.created")
      assert semantic.actor == "api"
      assert semantic.metadata["name"] == "from-the-api"

      # The pipeline plug still records the request itself. Deliberate while
      # the campaign is in flight — dropping it would take coverage away from
      # routes whose contexts do not audit yet (#552 decides its fate).
      assert find_action(user.id, "POST /api/agents")
    end
  end
end
