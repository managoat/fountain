defmodule Fountain.AgentsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents

  describe "create_agent/1" do
    test "creates an agent with valid attrs" do
      user = insert_verified_user()
      attrs = agent_attrs(user_id: user.id)

      assert {:ok, agent} = Agents.create_agent(attrs)
      assert agent.user_id == user.id
      assert agent.name == attrs["name"]
    end

    test "returns error changeset with missing required fields" do
      assert {:error, changeset} = Agents.create_agent(%{})
      assert changeset.errors != []
    end

    test "accepts an environment owned by the same user" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      attrs = agent_attrs(user_id: user.id, environment_id: env.id)

      assert {:ok, agent} = Agents.create_agent(attrs)
      assert agent.environment_id == env.id
    end

    test "rejects another tenant's environment" do
      attacker = insert_verified_user()
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)
      attrs = agent_attrs(user_id: attacker.id, environment_id: victim_env.id)

      assert {:error, changeset} = Agents.create_agent(attrs)
      assert %{environment_id: ["does not exist"]} = errors_on(changeset)
    end

    test "rejects a nonexistent environment with the same error as a foreign one" do
      user = insert_verified_user()
      attrs = agent_attrs(user_id: user.id, environment_id: Ecto.UUID.generate())

      assert {:error, changeset} = Agents.create_agent(attrs)
      assert %{environment_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "get_agent/2" do
    test "a malformed id reads as nil rather than raising (#1679)" do
      user = insert_verified_user()

      assert Agents.get_agent("prod-steward", user.id) == nil
      assert Agents.get_agent("warehouse worker", user.id) == nil
    end

    test "returns agent scoped to user" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert fetched = Agents.get_agent(agent.id, user.id)
      assert fetched.id == agent.id
    end

    test "returns nil for agent belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      agent = insert_agent(user_id: user_a.id)

      assert Agents.get_agent(agent.id, user_b.id) == nil
    end

    test "returns nil for non-existent id" do
      user = insert_verified_user()
      assert Agents.get_agent(Ecto.UUID.generate(), user.id) == nil
    end
  end

  describe "get_agent!/2" do
    test "raises for agent belonging to another user" do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      agent = insert_agent(user_id: user_a.id)

      assert_raise Ecto.NoResultsError, fn ->
        Agents.get_agent!(agent.id, user_b.id)
      end
    end
  end

  describe "list_agents/2" do
    test "returns only agents for the given user" do
      user_a = insert_user_without_agents()
      user_b = insert_user_without_agents()
      agent_a = insert_agent(user_id: user_a.id)
      _agent_b = insert_agent(user_id: user_b.id)

      results = Agents.list_agents(user_a.id, [])
      assert length(results) == 1
      assert hd(results).id == agent_a.id
    end

    test "returns empty list when user has no agents" do
      user = insert_user_without_agents()
      assert Agents.list_agents(user.id, []) == []
    end

    test "search filter matches agent name" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, name: "alpha bot")
      insert_agent(user_id: user.id, name: "beta bot")

      results = Agents.list_agents(user.id, search: "alpha")
      assert length(results) == 1
      assert hd(results).name == "alpha bot"
    end

    test "search filter returns empty when no match" do
      user = insert_verified_user()
      insert_agent(user_id: user.id, name: "gamma bot")

      results = Agents.list_agents(user.id, search: "zzz")
      assert results == []
    end

    test "runtimes filter returns only matching agents" do
      user = insert_user_without_agents()
      insert_agent(user_id: user.id, runtime: "claude")
      insert_agent(user_id: user.id, runtime: "claude")

      results = Agents.list_agents(user.id, runtimes: ["claude"])
      assert length(results) == 2
    end
  end

  describe "update_agent/2" do
    test "a name where an environment id belongs is a changeset error, not a raise (#1679)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, changeset} = Agents.update_agent(agent, %{"environment_id" => "toolchain"})
      assert %{environment_id: [message]} = errors_on(changeset)
      assert message == ~s(must be an id, but "toolchain" is not one)
    end

    test "updates agent fields" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:ok, updated} = Agents.update_agent(agent, %{"name" => "renamed"})
      assert updated.name == "renamed"
    end

    test "returns error changeset for invalid update" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, changeset} = Agents.update_agent(agent, %{"name" => nil})
      assert changeset.errors != []
    end

    test "accepts switching to an environment owned by the same user" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      agent = insert_agent(user_id: user.id)

      assert {:ok, updated} = Agents.update_agent(agent, %{"environment_id" => env.id})
      assert updated.environment_id == env.id
    end

    test "rejects switching to another tenant's environment" do
      attacker = insert_verified_user()
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)
      agent = insert_agent(user_id: attacker.id)

      assert {:error, changeset} =
               Agents.update_agent(agent, %{"environment_id" => victim_env.id})

      assert %{environment_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "delete_agent/1" do
    test "deletes the agent" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:ok, _deleted} = Agents.delete_agent(agent)
      assert Agents.get_agent(agent.id, user.id) == nil
    end
  end

  describe "versions" do
    test "create_agent writes version 1 with the full config" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, system: "be helpful")

      assert [v1] = Agents.list_agent_versions(agent.id, user.id)
      assert v1.version == 1
      assert v1.config == Agents.snapshot_config(agent)
      assert v1.config["system"] == "be helpful"
    end

    test "a config update writes the next version; a non-config write does not" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      {:ok, updated} = Agents.update_agent(agent, %{"system" => "be terse"})

      assert [v2, v1] = Agents.list_agent_versions(agent.id, user.id)
      assert {v2.version, v1.version} == {2, 1}
      assert v2.config == Agents.snapshot_config(updated)

      # A save that moves nothing writes nothing.
      {:ok, _} = Agents.update_agent(updated, %{"system" => "be terse"})
      assert length(Agents.list_agent_versions(agent.id, user.id)) == 2
    end

    test "an edit from a stale agent snapshots the persisted configuration" do
      user = insert_verified_user()
      original = insert_agent(user_id: user.id, system: "original instructions")

      assert {:ok, _} = Agents.update_agent(original, %{system: "revised instructions"})
      assert {:ok, updated} = Agents.update_agent(original, %{description: "a second edit"})

      persisted = Agents.get_agent(original.id, user.id)
      assert persisted.system == "revised instructions"
      assert persisted.description == "a second edit"
      assert Agents.snapshot_config(updated) == Agents.snapshot_config(persisted)

      assert [v3, v2, v1] = Agents.list_agent_versions(original.id, user.id)
      assert {v3.version, v2.version, v1.version} == {3, 2, 1}
      assert v3.config == Agents.snapshot_config(persisted)
      assert v2.config["system"] == "revised instructions"
      assert v1.config["system"] == "original instructions"
    end

    test "a rejected update writes no version" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      {:error, _} = Agents.update_agent(agent, %{"name" => nil})
      assert [_v1] = Agents.list_agent_versions(agent.id, user.id)
    end

    test "versions are tenant-scoped" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert Agents.list_agent_versions(agent.id, other.id) == []
      assert Agents.get_agent_version(agent.id, 1, other.id) == nil
    end

    test "rollback_agent restores the old config as a new version" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, system: "be helpful")
      {:ok, updated} = Agents.update_agent(agent, %{"system" => "be terse"})

      v1 = Agents.get_agent_version(agent.id, 1, user.id)
      assert {:ok, rolled_back} = Agents.rollback_agent(updated, v1)

      assert rolled_back.system == "be helpful"
      assert [v3 | _] = Agents.list_agent_versions(agent.id, user.id)
      assert v3.version == 3
      assert v3.config == v1.config
    end

    test "_unsafe_current_version_id tracks the newest version" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      v1_id = Agents._unsafe_current_version_id(agent.id)
      assert v1_id == Agents.get_agent_version(agent.id, 1, user.id).id

      {:ok, _} = Agents.update_agent(agent, %{"description" => "edited"})

      assert Agents._unsafe_current_version_id(agent.id) ==
               Agents.get_agent_version(agent.id, 2, user.id).id
    end

    test "versions go with the agent on delete" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      {:ok, _} = Agents.delete_agent(agent)
      assert Agents.list_agent_versions(agent.id, user.id) == []
    end

    test "an agent with a versioned conversation can still be deleted" do
      # Deleting the agent cascades to its versions, and Postgres re-checked
      # the conversation's version FK mid-cascade — before its own SET NULL —
      # so every agent with a conversation stamped by #1049 refused to go.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {:ok, agent} = Agents.update_agent(agent, %{"description" => "v2"})
      version_id = Agents._unsafe_current_version_id(agent.id)
      conv = insert_conversation(user_id: user.id, agent: agent, agent_version_id: version_id)
      assert conv.agent_version_id == version_id

      assert {:ok, _} = Agents.delete_agent(agent)

      reloaded = Fountain.Conversations._unsafe_get_conversation!(conv.id)
      assert is_nil(reloaded.agent_id)
      assert is_nil(reloaded.agent_version_id)
    end
  end

  describe "_unsafe_get_agent/1 and _unsafe_get_agent!/1" do
    test "_unsafe_get_agent returns the agent by id" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      result = Agents._unsafe_get_agent(agent.id)
      assert result.id == agent.id
    end

    test "_unsafe_get_agent returns nil for unknown id" do
      assert Agents._unsafe_get_agent(Ecto.UUID.generate()) == nil
    end

    test "_unsafe_get_agent! returns the agent by id" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      result = Agents._unsafe_get_agent!(agent.id)
      assert result.id == agent.id
    end

    test "_unsafe_get_agent! raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Agents._unsafe_get_agent!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_agents/2 - env_ids filter" do
    test "env_ids: [\"none\"] returns only agents with no environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      agent_no_env = insert_agent(user_id: user.id)
      _agent_with_env = insert_agent(user_id: user.id, environment_id: env.id)

      results = Agents.list_agents(user.id, env_ids: ["none"])
      ids = Enum.map(results, & &1.id)
      assert agent_no_env.id in ids
      refute Enum.any?(results, &(&1.environment_id != nil))
    end

    test "env_ids: [env.id] returns only agents with that environment" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      _agent_no_env = insert_agent(user_id: user.id)
      agent_with_env = insert_agent(user_id: user.id, environment_id: env.id)

      results = Agents.list_agents(user.id, env_ids: [env.id])
      assert length(results) == 1
      assert hd(results).id == agent_with_env.id
    end

    test "env_ids: [\"none\", env.id] returns agents with no env OR that env" do
      user = insert_user_without_agents()
      env_a = insert_env(user_id: user.id)
      env_b = insert_env(user_id: user.id)
      agent_no_env = insert_agent(user_id: user.id)
      agent_env_a = insert_agent(user_id: user.id, environment_id: env_a.id)
      _agent_env_b = insert_agent(user_id: user.id, environment_id: env_b.id)

      results = Agents.list_agents(user.id, env_ids: ["none", env_a.id])
      ids = Enum.map(results, & &1.id)
      assert agent_no_env.id in ids
      assert agent_env_a.id in ids
      assert length(results) == 2
    end
  end

  describe "list_agents/2 - has_skills filter" do
    test "has_skills: true returns only agents with non-empty skills list" do
      user = insert_verified_user()
      _agent_no_skills = insert_agent(user_id: user.id)

      agent_with_skills =
        insert_agent(
          user_id: user.id,
          skills: [%{"name" => "foo", "content" => "bar"}]
        )

      results = Agents.list_agents(user.id, has_skills: true)
      ids = Enum.map(results, & &1.id)
      assert agent_with_skills.id in ids
      refute Enum.any?(results, &(&1.skills == []))
    end

    test "has_skills: false (default) returns all agents including those without skills" do
      user = insert_verified_user()
      agent_no_skills = insert_agent(user_id: user.id)

      agent_with_skills =
        insert_agent(
          user_id: user.id,
          skills: [%{"name" => "foo", "content" => "bar"}]
        )

      results = Agents.list_agents(user.id, has_skills: false)
      ids = Enum.map(results, & &1.id)
      assert agent_no_skills.id in ids
      assert agent_with_skills.id in ids
    end
  end

  describe "list_agents/2 - has_mcp filter" do
    test "has_mcp: true returns only agents with non-empty mcp_servers map" do
      user = insert_verified_user()
      _agent_no_mcp = insert_agent(user_id: user.id)

      agent_with_mcp =
        insert_agent(
          user_id: user.id,
          mcp_servers: %{"my-server" => %{"url" => "http://localhost:8080"}}
        )

      results = Agents.list_agents(user.id, has_mcp: true)
      ids = Enum.map(results, & &1.id)
      assert agent_with_mcp.id in ids
      refute Enum.any?(results, &(&1.mcp_servers == %{}))
    end

    test "has_mcp: false (default) returns all agents" do
      user = insert_verified_user()
      agent_no_mcp = insert_agent(user_id: user.id)

      agent_with_mcp =
        insert_agent(
          user_id: user.id,
          mcp_servers: %{"my-server" => %{"url" => "http://localhost:8080"}}
        )

      results = Agents.list_agents(user.id, has_mcp: false)
      ids = Enum.map(results, & &1.id)
      assert agent_no_mcp.id in ids
      assert agent_with_mcp.id in ids
    end
  end

  describe "list_agents_with_counts/2" do
    test "returns conversation_count 0 for agent with no conversations" do
      user = insert_user_without_agents()
      _agent = insert_agent(user_id: user.id)

      results = Agents.list_agents_with_counts(user.id, [])
      assert length(results) == 1
      assert hd(results).conversation_count == 0
    end

    test "does not return agents belonging to another user" do
      user_a = insert_user_without_agents()
      user_b = insert_user_without_agents()
      agent_a = insert_agent(user_id: user_a.id)
      _agent_b = insert_agent(user_id: user_b.id)

      results = Agents.list_agents_with_counts(user_a.id, [])
      assert length(results) == 1
      assert hd(results).id == agent_a.id
    end

    test "returns correct conversation_count for agent with conversations" do
      user = insert_user_without_agents()
      agent = insert_agent(user_id: user.id)
      insert_conversation(user_id: user.id, agent_id: agent.id)
      insert_conversation(user_id: user.id, agent_id: agent.id)

      results = Agents.list_agents_with_counts(user.id, [])
      assert length(results) == 1
      assert hd(results).conversation_count == 2
    end

    test "does not count conversations belonging to other agents" do
      user = insert_user_without_agents()
      agent_a = insert_agent(user_id: user.id)
      agent_b = insert_agent(user_id: user.id)
      insert_conversation(user_id: user.id, agent_id: agent_b.id)

      results = Agents.list_agents_with_counts(user.id, [])
      a_result = Enum.find(results, &(&1.id == agent_a.id))
      assert a_result.conversation_count == 0
    end

    test "accepts the same filters as list_agents/2" do
      user = insert_user_without_agents()
      insert_agent(user_id: user.id, name: "alpha", runtime: "claude")
      insert_agent(user_id: user.id, name: "beta", runtime: "gemini")

      results = Agents.list_agents_with_counts(user.id, runtimes: ["claude"])
      assert length(results) == 1
      assert hd(results).name == "alpha"
    end

    test "does not count conversations belonging to another user" do
      user_a = insert_user_without_agents()
      user_b = insert_user_without_agents()
      agent = insert_agent(user_id: user_a.id)
      insert_conversation(user_id: user_b.id, agent_id: agent.id)

      results = Agents.list_agents_with_counts(user_a.id, [])
      assert length(results) == 1
      assert hd(results).conversation_count == 0
    end

    test "preloads the environment association" do
      user = insert_user_without_agents()
      env = insert_env(user_id: user.id)
      _agent = insert_agent(user_id: user.id, environment_id: env.id)

      results = Agents.list_agents_with_counts(user.id, [])
      assert hd(results).environment.id == env.id
    end
  end

  describe "permission_policy (#939)" do
    test "defaults to an empty map, which means auto_allow" do
      agent = insert_agent(user_id: insert_verified_user().id)
      assert agent.permission_policy == %{}
      assert Managoat.ACP.Permissions.verdict_for(agent.permission_policy, "Bash") == "auto_allow"
    end

    test "accepts a per-tool map with a default" do
      user = insert_verified_user()
      policy = %{"default" => "auto_allow", "Bash" => "auto_deny"}
      agent = insert_agent(user_id: user.id, permission_policy: policy)
      assert agent.permission_policy == policy
    end

    test "rejects an unknown verdict rather than failing closed silently" do
      user = insert_verified_user()

      assert {:error, changeset} =
               Agents.create_agent(
                 agent_attrs(%{
                   "user_id" => user.id,
                   "permission_policy" => %{"Bash" => "banana"}
                 })
               )

      assert %{permission_policy: [msg]} = errors_on(changeset)
      assert msg =~ "unknown verdict"
    end

    test "accepts ask, now that #940 gave it somewhere to ask" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, permission_policy: %{"Bash" => "ask"})
      assert agent.permission_policy == %{"Bash" => "ask"}
    end

    test "rejects a non-string tool key" do
      user = insert_verified_user()

      assert {:error, changeset} =
               Agents.create_agent(
                 agent_attrs(%{"user_id" => user.id, "permission_policy" => %{"" => "auto_deny"}})
               )

      assert %{permission_policy: _} = errors_on(changeset)
    end

    test "ask_timeout is seconds, not a verdict, and is stored beside the tools (#1635)" do
      user = insert_verified_user()

      agent =
        insert_agent(
          user_id: user.id,
          permission_policy: %{"execute" => "ask", "ask_timeout" => 172_800}
        )

      assert agent.permission_policy == %{"execute" => "ask", "ask_timeout" => 172_800}
      assert Fountain.PermissionPolicy.ask_timeout_seconds(agent.permission_policy) == 172_800

      # And it names no tool, so it never reaches the library that reads a key
      # as one.
      refute Map.has_key?(
               Fountain.PermissionPolicy.verdicts(agent.permission_policy),
               "ask_timeout"
             )
    end

    test "an ask_timeout that is not a positive number of seconds is refused" do
      user = insert_verified_user()

      for value <- [0, -1, "soon", "60s"] do
        assert {:error, changeset} =
                 Agents.create_agent(
                   agent_attrs(%{
                     "user_id" => user.id,
                     "permission_policy" => %{"ask_timeout" => value}
                   })
                 )

        assert %{permission_policy: [msg]} = errors_on(changeset)
        assert msg =~ "positive number of seconds"
      end
    end

    test "an ask_timeout past the ceiling is refused at the door, not at the deadline" do
      # Unbounded, this stored fine and then raised days later: the deadline
      # is `now + ask_timeout` on `turns.permission_deadline`, and 1e15
      # seconds put it at year 31690765, which Postgrex refused to encode
      # inside the `handle_info` that detaches the request. The turn was left
      # `running` with the request neither detached nor denied.
      user = insert_verified_user()
      max = Fountain.PermissionPolicy.max_ask_timeout_seconds()

      for value <- [max + 1, 999_999_999_999_999, "999999999999999"] do
        assert {:error, changeset} =
                 Agents.create_agent(
                   agent_attrs(%{
                     "user_id" => user.id,
                     "permission_policy" => %{"execute" => "ask", "ask_timeout" => value}
                   })
                 )

        assert %{permission_policy: [msg]} = errors_on(changeset)
        assert msg =~ "no greater than #{max}"
      end

      # And the ceiling itself is storable, so the refusal is a bound and not
      # an off-by-one.
      agent =
        insert_agent(
          user_id: user.id,
          permission_policy: %{"execute" => "ask", "ask_timeout" => max}
        )

      assert agent.permission_policy["ask_timeout"] == max
    end

    test "a policy change is audited by the existing agent.updated trail" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      {:ok, _} = Agents.update_agent(agent, %{"permission_policy" => %{"Bash" => "auto_deny"}})

      assert [event] =
               user.id
               |> Fountain.Audit.list_recent_for_user(10)
               |> Enum.filter(&(&1.action == "agent.updated"))

      assert "permission_policy" in event.metadata["changed"]
    end
  end
end
