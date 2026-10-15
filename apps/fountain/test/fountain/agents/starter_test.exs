defmodule Fountain.Agents.StarterTest do
  @moduledoc """
  The default agent every account is verified into owning (ADR 0038, #1389).

  The behaviour worth pinning is in two halves. One is that it is *there*: a
  freshly verified account has exactly one agent, from every door that finishes
  a verification, and the trail says the system made it rather than the account.
  The other is that it is *ordinary*: nothing recreates it, nothing protects it,
  and no code path reads its name. The second half is the one a later change is
  likely to break, which is why deleting it is asserted here rather than assumed.
  """

  use Fountain.DataCase, async: true

  alias Fountain.{Accounts, Agents, Audit}
  alias Fountain.Agents.ModelCatalog
  alias Fountain.Agents.Starter

  defp agents(user), do: Agents.list_agents(user.id, [])

  defp agent_created_events(user) do
    user.id
    |> Audit.list_recent_for_user(200)
    |> Enum.filter(&(&1.action == "agent.created"))
  end

  describe "verification plants it" do
    test "a freshly verified account has exactly one agent" do
      user = insert_verified_user()

      assert [agent] = agents(user)
      assert agent.name == "starter"
      assert agent.runtime == "claude"
      assert agent.user_id == user.id
    end

    test "it is configured to need nothing: no environment, no MCP, no skills" do
      # The three things the first screen used to ask for. An agent that needed
      # any of them would not be an agent a blank account can run.
      assert [agent] = agents(insert_verified_user())

      assert agent.environment_id == nil
      assert agent.mcp_servers == %{}
      assert agent.skills == []
    end

    test "its prompt says what it is and whose inference key it runs on" do
      assert [agent] = agents(insert_verified_user())

      assert agent.system =~ "starter"
      assert agent.system =~ "own inference credential"
      assert agent.system =~ "credential"
      assert agent.description != ""
    end

    test "an OAuth signup has exactly one, with the same audit trail" do
      # OAuth inserts the account already verified, so it never passes through
      # verify_email/2. It runs the same post-commit steps instead; before it
      # did, an OAuth signup started with no agent at all.
      assert {:ok, user, :new} =
               Accounts.upsert_oauth_user("github", "gh-starter-#{System.unique_integer()}", %{
                 "email" => "oauth-starter-#{System.unique_integer([:positive])}@example.com"
               })

      assert [agent] = agents(user)
      assert agent.name == "starter"
      assert [event] = agent_created_events(user)
      assert event.actor == "system:onboarding"
    end

    test "an account an admin opens has exactly one, with the same audit trail" do
      # ADR 0064: the account is inserted verified, so like an OAuth signup it
      # never passes through verify_email/2 and runs the same steps itself.
      {:ok, admin} = Accounts.update_user_role(insert_verified_user(), "admin")

      assert {:ok, {user, _raw}} =
               Accounts.create_account_by_admin(
                 admin,
                 "admin-starter-#{System.unique_integer([:positive])}@example.com"
               )

      assert [agent] = agents(user)
      assert agent.name == "starter"
      assert agent.user_id == user.id
      assert [event] = agent_created_events(user)
      assert event.actor == "system:onboarding"
      assert event.resource_id == agent.id
    end

    test "an OAuth sign-in to an existing account plants nothing more" do
      # Linking a new identity to an account, or signing in with a known one,
      # is not a verification: a deleted starter stays deleted.
      user = insert_verified_user()
      [agent] = agents(user)
      {:ok, _} = Agents.delete_agent(agent)

      uid = "gh-link-#{System.unique_integer()}"

      assert {:ok, _, :existing} =
               Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})

      assert {:ok, _, :existing} =
               Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})

      assert agents(user) == []
    end

    test "an unverified account has no agent" do
      # Nothing is created for an account until it verifies (ADR 0038).
      user = insert_user()

      assert agents(user) == []
    end
  end

  describe "the audit trail" do
    test "records agent.created with actor system:onboarding" do
      user = insert_verified_user()

      assert [event] = agent_created_events(user)
      assert event.actor == "system:onboarding"
      assert event.resource_type == "agent"
      assert event.metadata["name"] == "starter"
    end

    test "the actor is not `self` — the account did not ask for this" do
      user = insert_verified_user()

      refute Enum.any?(agent_created_events(user), &(&1.actor == "self"))
    end
  end

  describe "it is an ordinary agent" do
    test "it can be renamed, re-pointed and re-prompted like any other" do
      user = insert_verified_user()
      [agent] = agents(user)

      assert {:ok, updated} =
               Agents.update_agent(agent, %{
                 "name" => "mine",
                 "model" => "anthropic/claude-opus-5",
                 "system" => "Do as I say."
               })

      assert updated.name == "mine"
      assert updated.model == "anthropic/claude-opus-5"
    end

    test "deleting it leaves the account with no agents, and nothing brings it back" do
      user = insert_verified_user()
      [agent] = agents(user)

      assert {:ok, _} = Agents.delete_agent(agent)
      assert agents(user) == []

      # Re-running a verification route on an already-verified account is the
      # way this would resurrect. It must not: the account deleted it.
      {:ok, _} = Accounts.verify_email(Fountain.Repo.reload!(user))

      assert agents(user) == []
    end
  end

  describe "create_for/2" do
    test "is idempotent per account" do
      user = insert_verified_user()

      assert {:ok, :exists} = Starter.create_for(user.id)
      assert length(agents(user)) == 1
    end

    test "plants one for an account that has none" do
      user = insert_user_without_agents()

      assert {:ok, agent} = Starter.create_for(user.id)
      assert agent.name == "starter"
      assert [_] = agents(user)
    end

    test "the model is a canonical provider/model_id under the claude runtime" do
      # `Agent.changeset/2` rejects a mismatched prefix, so a wrong default here
      # would fail every verification's planting silently (best-effort) and
      # leave new accounts empty. Asserted rather than trusted to the insert.
      attrs = Starter.attrs(Ecto.UUID.generate())

      assert attrs["runtime"] == "claude"
      assert attrs["model"] =~ ~r"^anthropic/"
    end

    # The prefix check above is gate one — the provider. It is the half
    # `ModelCatalog`'s two-gates note calls necessary and not sufficient, and
    # the starter agent is the highest-stakes place to get gate two wrong:
    # `@model` becomes the model of the one agent every verified account owns
    # (ADR 0038 decision 4), so an id the pinned adapter refuses would fail the
    # first request every new account makes, before any prompt is written.
    test "the model is a current catalog entry, not merely an anthropic id" do
      model = Starter.attrs(Ecto.UUID.generate())["model"]

      refute model in Fountain.RefusedModels.ids(),
             "the starter agent is pinned to #{model}, which the pinned ACP adapter refuses"

      assert ModelCatalog.known?(model),
             "the starter agent is pinned to #{model}, which is not in the catalog"
    end
  end
end
