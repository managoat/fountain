defmodule Fountain.Agents.VaultAccessTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents
  alias Fountain.Agents.{Agent, AgentVersion}

  test "create and update return the generated policy, including old input shapes" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    agent = insert_agent(user_id: user.id)
    assert agent.vault_access == "all_tenant_vaults"
    assert Agent.vault_allowed?(agent, vault.id)

    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_vault_ids" => []})
    assert agent.vault_access == "allowlist"
    refute Agent.vault_allowed?(agent, vault.id)

    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_vault_ids" => [vault.id]})
    assert agent.vault_access == "allowlist"
    assert Agent.vault_allowed?(agent, vault.id)
    refute Agent.vault_allowed?(agent, Ecto.UUID.generate())

    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_vault_ids" => nil})
    assert agent.vault_access == "all_tenant_vaults"
    assert Agent.vault_allowed?(agent, vault.id)
  end

  test "an old writer updating only the array also updates the persisted policy" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    query = from(a in Agent, where: a.id == ^agent.id and a.user_id == ^user.id)

    for {ids, mode} <- [
          {[], "allowlist"},
          {[Ecto.UUID.generate()], "allowlist"},
          {nil, "all_tenant_vaults"}
        ] do
      assert {1, _} = Repo.update_all(query, set: [allowed_vault_ids: ids])
      assert %{vault_access: ^mode, allowed_vault_ids: ^ids} = Agents.get_agent(agent.id, user.id)
    end
  end

  test "client-supplied mode cannot widen a deny-all policy" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_vault_ids: [])
    assert {:ok, agent} = Agents.update_agent(agent, %{"vault_access" => "all_tenant_vaults"})
    assert agent.vault_access == "allowlist"
    refute Agent.vault_allowed?(agent, Ecto.UUID.generate())
  end

  test "unknown, unsaved and inconsistent in-memory policies fail closed" do
    user = insert_verified_user()
    vault_id = Ecto.UUID.generate()
    open = insert_agent(user_id: user.id)
    closed = insert_agent(user_id: user.id, allowed_vault_ids: [])

    for agent <- [
          %Agent{},
          %Agent{vault_access: "all_tenant_vaults"},
          %Agent{vault_access: "allowlist", allowed_vault_ids: [vault_id]},
          %{open | vault_access: nil},
          %{open | vault_access: "unexpected"},
          %{open | allowed_vault_ids: []},
          %{open | allowed_vault_ids: [vault_id]},
          %{closed | allowed_vault_ids: nil}
        ] do
      refute Agent.vault_allowed?(agent, vault_id)
    end
  end

  test "saved versions restore unrestricted, deny-all and finite policies without rewriting history" do
    user = insert_verified_user()
    vault = insert_vault(user_id: user.id)
    agent = insert_agent(user_id: user.id)
    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_vault_ids" => []})
    assert {:ok, agent} = Agents.update_agent(agent, %{"allowed_vault_ids" => [vault.id]})
    versions = Agents.list_agent_versions(agent.id, user.id)

    for version <- versions do
      assert {:ok, restored} = restore(Agents.get_agent(agent.id, user.id), version)
      assert restored.allowed_vault_ids == version.config["allowed_vault_ids"]
      assert restored.vault_access == version.vault_access
      assert Repo.reload!(version).config == version.config
    end

    future_vault = insert_vault(user_id: user.id)
    unrestricted = Agents.get_agent_version(agent.id, 1, user.id)

    assert {:ok, restored} =
             restore(Agents.get_agent(agent.id, user.id), unrestricted)

    assert Agent.vault_allowed?(restored, future_vault.id)
  end

  test "a historical snapshot omitting the key leaves the current policy unchanged" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_vault_ids: [])
    version = insert_version(agent, %{"name" => "partial restore"})
    assert version.vault_access == "unchanged"
    refute Map.has_key?(version.config, "allowed_vault_ids")
    assert {:ok, restored} = restore(agent, version)
    assert restored.name == "partial restore"
    assert restored.allowed_vault_ids == []
    assert restored.vault_access == "allowlist"
    refute Agent.vault_allowed?(restored, Ecto.UUID.generate())
    assert Repo.reload!(version).config == %{"name" => "partial restore"}
  end

  test "explicit null in a historical snapshot restores unrestricted access" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_vault_ids: [])
    version = insert_version(agent, %{"allowed_vault_ids" => nil})
    assert version.vault_access == "all_tenant_vaults"
    assert {:ok, restored} = restore(agent, version)
    assert restored.vault_access == "all_tenant_vaults"
    assert Agent.vault_allowed?(restored, Ecto.UUID.generate())
  end

  test "malformed historical policy has no inferred access and is rejected on restore" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, allowed_vault_ids: [])
    version = insert_version(agent, %{"allowed_vault_ids" => "all"})
    assert version.vault_access == "invalid"
    assert {:error, changeset} = restore(agent, version)
    assert %{allowed_vault_ids: [_]} = errors_on(changeset)
    assert Agents.get_agent(agent.id, user.id).allowed_vault_ids == []
  end

  # The documented way back to a version: write its config to the agent again.
  defp restore(agent, version), do: Agents.update_agent(agent, version.config)

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
