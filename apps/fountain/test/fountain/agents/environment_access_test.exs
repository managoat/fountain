defmodule Fountain.Agents.EnvironmentAccessTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents
  alias Fountain.Agents.{Agent, AgentVersion}

  test "create and update return the generated policy, including old input shapes" do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id)
    assert agent.environment_access == "all_tenant_environments"
    assert Agent.environment_allowed?(agent, env.id)

    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_environment_ids" => []})
    assert agent.environment_access == "allowlist"
    refute Agent.environment_allowed?(agent, env.id)

    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_environment_ids" => [env.id]})
    assert agent.environment_access == "allowlist"
    assert Agent.environment_allowed?(agent, env.id)
    refute Agent.environment_allowed?(agent, Ecto.UUID.generate())

    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_environment_ids" => nil})
    assert agent.environment_access == "all_tenant_environments"
    assert Agent.environment_allowed?(agent, env.id)
  end

  test "an environment created after the migration is reachable under all, not under allowlist" do
    user = insert_verified_user()
    open = insert_agent(user_id: user.id)
    closed = insert_agent(user_id: user.id, allowed_environment_ids: [])
    future = insert_env(user_id: user.id)

    assert Agent.environment_allowed?(open, future.id)
    refute Agent.environment_allowed?(closed, future.id)
  end

  test "the agent's own environment passes whatever the policy says" do
    user = insert_verified_user()
    own = insert_env(user_id: user.id)
    other = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: own.id, allowed_environment_ids: [])

    assert agent.environment_access == "allowlist"
    assert Agent.environment_allowed?(agent, own.id)
    refute Agent.environment_allowed?(agent, other.id)
  end

  test "an old writer updating only the array also updates the persisted policy" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    query = from(a in Agent, where: a.id == ^agent.id and a.user_id == ^user.id)

    for {ids, mode} <- [
          {[], "allowlist"},
          {[Ecto.UUID.generate()], "allowlist"},
          {nil, "all_tenant_environments"}
        ] do
      assert {1, _} = Repo.update_all(query, set: [allowed_environment_ids: ids])

      assert %{environment_access: ^mode, allowed_environment_ids: ^ids} =
               Agents.get_agent(agent.id, user.id)
    end
  end

  test "client-supplied mode cannot widen a deny-all policy" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_environment_ids: [])

    assert {:ok, agent} =
             Agents.update_agent(agent, %{"environment_access" => "all_tenant_environments"})

    assert agent.environment_access == "allowlist"
    refute Agent.environment_allowed?(agent, Ecto.UUID.generate())
  end

  test "unknown, unsaved and inconsistent in-memory policies fail closed" do
    user = insert_verified_user()
    env_id = Ecto.UUID.generate()
    open = insert_agent(user_id: user.id)
    closed = insert_agent(user_id: user.id, allowed_environment_ids: [])

    for agent <- [
          %Agent{},
          %Agent{environment_access: "all_tenant_environments"},
          %Agent{environment_access: "allowlist", allowed_environment_ids: [env_id]},
          %Agent{environment_id: env_id},
          %{open | environment_access: nil},
          %{open | environment_access: "unexpected"},
          %{open | allowed_environment_ids: []},
          %{open | allowed_environment_ids: [env_id]},
          %{closed | allowed_environment_ids: nil}
        ] do
      refute Agent.environment_allowed?(agent, env_id)
    end
  end

  test "saved versions restore unrestricted, deny-all and finite policies without rewriting history" do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id)
    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_environment_ids" => []})
    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_environment_ids" => [env.id]})
    versions = Agents.list_agent_versions(agent.id, user.id)

    for version <- versions do
      assert {:ok, restored} = Agents.rollback_agent(Agents.get_agent(agent.id, user.id), version)
      assert restored.allowed_environment_ids == version.config["allowed_environment_ids"]
      assert restored.environment_access == version.environment_access
      assert Repo.reload!(version).config == version.config
    end

    future_env = insert_env(user_id: user.id)
    unrestricted = Agents.get_agent_version(agent.id, 1, user.id)

    assert {:ok, restored} =
             Agents.rollback_agent(Agents.get_agent(agent.id, user.id), unrestricted)

    assert Agent.environment_allowed?(restored, future_env.id)
  end

  test "a historical snapshot omitting the key leaves the current policy unchanged" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_environment_ids: [])
    version = insert_version(agent, %{"name" => "partial restore"})
    assert version.environment_access == "unchanged"
    refute Map.has_key?(version.config, "allowed_environment_ids")
    assert {:ok, restored} = Agents.rollback_agent(agent, version)
    assert restored.name == "partial restore"
    assert restored.allowed_environment_ids == []
    assert restored.environment_access == "allowlist"
    refute Agent.environment_allowed?(restored, Ecto.UUID.generate())
    assert Repo.reload!(version).config == %{"name" => "partial restore"}
  end

  test "explicit null in a historical snapshot restores unrestricted access" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_environment_ids: [])
    version = insert_version(agent, %{"allowed_environment_ids" => nil})
    assert version.environment_access == "all_tenant_environments"
    assert {:ok, restored} = Agents.rollback_agent(agent, version)
    assert restored.environment_access == "all_tenant_environments"
    assert Agent.environment_allowed?(restored, Ecto.UUID.generate())
  end

  test "malformed historical policy has no inferred access and is rejected on restore" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_environment_ids: [])
    version = insert_version(agent, %{"allowed_environment_ids" => "all"})
    assert version.environment_access == "invalid"
    assert {:error, changeset} = Agents.rollback_agent(agent, version)
    assert %{allowed_environment_ids: [_]} = errors_on(changeset)
    assert Agents.get_agent(agent.id, user.id).allowed_environment_ids == []
  end

  defp insert_version(agent, config) do
    %AgentVersion{}
    |> AgentVersion.changeset(%{
      agent_id: agent.id,
      user_id: agent.user_id,
      version: 99,
      config: config
    })
    |> Repo.insert!()
  end
end
