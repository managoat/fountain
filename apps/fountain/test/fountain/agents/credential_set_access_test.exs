defmodule Fountain.Agents.CredentialSetAccessTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents
  alias Fountain.Agents.{Agent, AgentVersion}
  alias Fountain.InferenceCredentials

  setup do
    user = insert_verified_user()
    {:ok, set} = InferenceCredentials.create_set(user.id, "First")
    %{user: user, set: set}
  end

  test "create and update return the generated policy, including old input shapes", ctx do
    agent = insert_agent(user_id: ctx.user.id)
    assert agent.inference_credential_access == "all_tenant_credential_sets"
    assert Agent.credential_set_allowed?(agent, ctx.set.id)

    assert {:ok, agent} =
             Agents.update_agent(agent, %{"allowed_inference_credential_ids" => []})

    assert agent.inference_credential_access == "allowlist"
    refute Agent.credential_set_allowed?(agent, ctx.set.id)

    assert {:ok, agent} =
             Agents.update_agent(agent, %{"allowed_inference_credential_ids" => [ctx.set.id]})

    assert agent.inference_credential_access == "allowlist"
    assert Agent.credential_set_allowed?(agent, ctx.set.id)
    refute Agent.credential_set_allowed?(agent, Ecto.UUID.generate())

    assert {:ok, agent} =
             Agents.update_agent(agent, %{"allowed_inference_credential_ids" => nil})

    assert agent.inference_credential_access == "all_tenant_credential_sets"
    assert Agent.credential_set_allowed?(agent, ctx.set.id)
  end

  test "a set created after the migration is reachable under all, not under allowlist", ctx do
    open = insert_agent(user_id: ctx.user.id)
    closed = insert_agent(user_id: ctx.user.id, allowed_inference_credential_ids: [])
    {:ok, future} = InferenceCredentials.create_set(ctx.user.id, "Later")

    assert Agent.credential_set_allowed?(open, future.id)
    refute Agent.credential_set_allowed?(closed, future.id)
  end

  test "the agent's own set passes whatever the policy says", ctx do
    {:ok, other} = InferenceCredentials.create_set(ctx.user.id, "Other")

    agent =
      insert_agent(
        user_id: ctx.user.id,
        inference_credential_id: ctx.set.id,
        allowed_inference_credential_ids: []
      )

    assert agent.inference_credential_access == "allowlist"
    assert Agent.credential_set_allowed?(agent, ctx.set.id)
    refute Agent.credential_set_allowed?(agent, other.id)
  end

  test "an old writer updating only the array also updates the persisted policy", ctx do
    agent = insert_agent(user_id: ctx.user.id)
    query = from(a in Agent, where: a.id == ^agent.id and a.user_id == ^ctx.user.id)

    for {ids, mode} <- [
          {[], "allowlist"},
          {[Ecto.UUID.generate()], "allowlist"},
          {nil, "all_tenant_credential_sets"}
        ] do
      assert {1, _} = Repo.update_all(query, set: [allowed_inference_credential_ids: ids])

      assert %{inference_credential_access: ^mode, allowed_inference_credential_ids: ^ids} =
               Agents.get_agent(agent.id, ctx.user.id)
    end
  end

  test "client-supplied mode cannot widen a deny-all policy", ctx do
    agent = insert_agent(user_id: ctx.user.id, allowed_inference_credential_ids: [])

    assert {:ok, agent} =
             Agents.update_agent(agent, %{
               "inference_credential_access" => "all_tenant_credential_sets"
             })

    assert agent.inference_credential_access == "allowlist"
    refute Agent.credential_set_allowed?(agent, Ecto.UUID.generate())
  end

  test "unknown, unsaved and inconsistent in-memory policies fail closed", ctx do
    set_id = ctx.set.id
    open = insert_agent(user_id: ctx.user.id)
    closed = insert_agent(user_id: ctx.user.id, allowed_inference_credential_ids: [])

    for agent <- [
          %Agent{},
          %Agent{inference_credential_access: "all_tenant_credential_sets"},
          %Agent{
            inference_credential_access: "allowlist",
            allowed_inference_credential_ids: [set_id]
          },
          %Agent{inference_credential_id: set_id},
          %{open | inference_credential_access: nil},
          %{open | inference_credential_access: "unexpected"},
          %{open | allowed_inference_credential_ids: []},
          %{open | allowed_inference_credential_ids: [set_id]},
          %{closed | allowed_inference_credential_ids: nil}
        ] do
      refute Agent.credential_set_allowed?(agent, set_id)
    end
  end

  test "saved versions restore unrestricted, deny-all and finite policies without rewriting history",
       ctx do
    agent = insert_agent(user_id: ctx.user.id)

    assert {:ok, agent} =
             Agents.update_agent(agent, %{"allowed_inference_credential_ids" => []})

    assert {:ok, agent} =
             Agents.update_agent(agent, %{"allowed_inference_credential_ids" => [ctx.set.id]})

    for version <- Agents.list_agent_versions(agent.id, ctx.user.id) do
      assert {:ok, restored} =
               Agents.rollback_agent(Agents.get_agent(agent.id, ctx.user.id), version)

      assert restored.allowed_inference_credential_ids ==
               version.config["allowed_inference_credential_ids"]

      assert restored.inference_credential_access == version.inference_credential_access
      assert Repo.reload!(version).config == version.config
    end

    {:ok, future} = InferenceCredentials.create_set(ctx.user.id, "Later")
    unrestricted = Agents.get_agent_version(agent.id, 1, ctx.user.id)

    assert {:ok, restored} =
             Agents.rollback_agent(Agents.get_agent(agent.id, ctx.user.id), unrestricted)

    assert Agent.credential_set_allowed?(restored, future.id)
  end

  test "a historical snapshot omitting the key leaves the current policy unchanged", ctx do
    agent = insert_agent(user_id: ctx.user.id, allowed_inference_credential_ids: [])
    version = insert_version(agent, %{"name" => "partial restore"})
    assert version.inference_credential_access == "unchanged"
    refute Map.has_key?(version.config, "allowed_inference_credential_ids")
    assert {:ok, restored} = Agents.rollback_agent(agent, version)
    assert restored.name == "partial restore"
    assert restored.allowed_inference_credential_ids == []
    assert restored.inference_credential_access == "allowlist"
    refute Agent.credential_set_allowed?(restored, Ecto.UUID.generate())
    assert Repo.reload!(version).config == %{"name" => "partial restore"}
  end

  test "explicit null in a historical snapshot restores unrestricted access", ctx do
    agent = insert_agent(user_id: ctx.user.id, allowed_inference_credential_ids: [])
    version = insert_version(agent, %{"allowed_inference_credential_ids" => nil})
    assert version.inference_credential_access == "all_tenant_credential_sets"
    assert {:ok, restored} = Agents.rollback_agent(agent, version)
    assert restored.inference_credential_access == "all_tenant_credential_sets"
    assert Agent.credential_set_allowed?(restored, Ecto.UUID.generate())
  end

  test "malformed historical policy has no inferred access and is rejected on restore", ctx do
    agent = insert_agent(user_id: ctx.user.id, allowed_inference_credential_ids: [])
    version = insert_version(agent, %{"allowed_inference_credential_ids" => "all"})
    assert version.inference_credential_access == "invalid"
    assert {:error, changeset} = Agents.rollback_agent(agent, version)
    assert %{allowed_inference_credential_ids: [_]} = errors_on(changeset)

    assert Agents.get_agent(agent.id, ctx.user.id).allowed_inference_credential_ids == []
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
