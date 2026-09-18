defmodule Fountain.ManifestTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Audit, Conversations, Crypto, Environments, Manifest, Team, Vaults}
  alias Fountain.Team.Schedules
  alias Fountain.Webhooks

  setup do
    # No starter agent (ADR 0038): every assertion here counts what the
    # manifest reconciled, and an agent the account was given is not that.
    %{user: insert_user_without_agents()}
  end

  defp env_resource(name, spec \\ %{}) do
    %{"kind" => "Environment", "name" => name, "spec" => spec}
  end

  defp vault_resource(name, spec \\ %{}) do
    %{"kind" => "Vault", "name" => name, "spec" => spec}
  end

  defp webhook_resource(name, spec) do
    %{"kind" => "Webhook", "name" => name, "spec" => spec}
  end

  defp schedule_resource(name, spec) do
    %{"kind" => "Schedule", "name" => name, "spec" => spec}
  end

  defp teammate_resource(name, spec) do
    %{"kind" => "Teammate", "name" => name, "spec" => spec}
  end

  # Adding a teammate opens its conversation, which provisions its computer.
  # The supervisor start is what a DataCase test cannot do for real.
  defp inert_start_child do
    stub_server_start(fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  defp agent_resource(name, spec \\ %{}) do
    spec =
      Map.merge(%{"model" => "anthropic/claude-sonnet-4-6", "runtime" => "claude"}, spec)

    %{"kind" => "Agent", "name" => name, "spec" => spec}
  end

  describe "spec keys" do
    test "rejects unknown keys on each kind before it creates records", %{user: user} do
      resources = [
        env_resource("bad-env", %{
          "network_policy" => "limited",
          "allowed_hosts" => ["example.test"]
        }),
        vault_resource("bad-vault", %{"descrption" => "private"}),
        agent_resource("bad-agent", %{"permisson_policy" => %{"default" => "auto_deny"}}),
        vault_resource("good-vault")
      ]

      assert {:ok, [env, vault, good, agent]} = Manifest.apply_manifest(user.id, resources)
      assert env.action == :error
      assert Enum.sort(Map.keys(env.errors)) == ["allowed_hosts", "network_policy"]
      assert vault.action == :error
      assert Map.has_key?(vault.errors, "descrption")
      assert agent.action == :error
      assert Map.has_key?(agent.errors, "permisson_policy")
      assert good.action == :created
      refute Environments.get_environment_by_name("bad-env", user.id)
      refute Vaults.get_vault_by_name("bad-vault", user.id)
      refute Agents.get_agent_by_name("bad-agent", user.id)
    end

    test "a rejected update writes neither attributes nor secrets", %{user: user} do
      assert {:ok, [%{action: :created}]} =
               Manifest.apply_manifest(user.id, [
                 env_resource("locked", %{
                   "setup_script" => "original",
                   "networking_type" => "limited",
                   "networking_config" => %{"allowed_hosts" => ["example.test"]},
                   "secrets" => %{"TOKEN" => "original"}
                 })
               ])

      assert {:ok, [%{action: :error, secrets: []}]} =
               Manifest.apply_manifest(user.id, [
                 env_resource("locked", %{
                   "setup_script" => "changed",
                   "network_policy" => "unrestricted",
                   "secrets" => %{"TOKEN" => "replacement"}
                 })
               ])

      env = Environments.get_environment_by_name("locked", user.id)
      assert env.setup_script == "original"
      assert env.networking_type == "limited"
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "original"}
    end

    test "database fields and secrets on an Agent are not accepted spec keys", %{user: user} do
      for resource <- [
            env_resource("e", %{"inserted_at" => "2026-01-01T00:00:00Z"}),
            vault_resource("v", %{"secret_count" => 4}),
            agent_resource("a", %{"avatar_media_type" => "image/png", "secrets" => %{}})
          ] do
        assert {:ok, [%{action: :error}]} = Manifest.apply_manifest(user.id, [resource])
      end
    end
  end

  describe "the acp runtime in a manifest (#1634)" do
    test "an Agent declares its runtime_command, and needs no model", %{user: user} do
      resource = %{
        "kind" => "Agent",
        "name" => "converger",
        "spec" => %{"runtime" => "acp", "runtime_command" => "exec chant acp --env prod"}
      }

      assert {:ok, [%{action: :created}]} = Manifest.apply_manifest(user.id, [resource])

      agent = Agents.get_agent_by_name("converger", user.id)
      assert agent.runtime == "acp"
      assert agent.runtime_command == "exec chant acp --env prod"
      assert is_nil(agent.model)
    end

    test "runtime_command on a model-driven runtime fails its own row", %{user: user} do
      resource = agent_resource("claudey", %{"runtime_command" => "chant acp"})

      assert {:ok, [%{action: :error, errors: errors}]} =
               Manifest.apply_manifest(user.id, [resource])

      assert Map.has_key?(errors, "runtime_command")
    end
  end

  describe "apply_manifest/2 creation" do
    test "creates environments, vaults, and agents with secrets", %{user: user} do
      resources = [
        agent_resource("researcher", %{"environment" => "proj"}),
        vault_resource("alice", %{"secrets" => %{"GH" => "ghp_x", "NPM" => "npm_y"}}),
        env_resource("proj", %{
          "setup_script" => "echo hi",
          "secrets" => %{"TOKEN" => "t0"}
        })
      ]

      {:ok, results} = Manifest.apply_manifest(user.id, resources)

      # Reconciliation order is envs, vaults, agents regardless of input order.
      assert [
               %{kind: "Environment", name: "proj", action: :created, secrets: [env_secret]},
               %{kind: "Vault", name: "alice", action: :created, secrets: vault_secrets},
               %{kind: "Agent", name: "researcher", action: :created}
             ] = results

      assert env_secret == %{key: "TOKEN", action: :upserted, errors: nil}
      assert Enum.map(vault_secrets, & &1.key) == ["GH", "NPM"]

      env = Environments.get_environment_by_name("proj", user.id)
      assert env.setup_script == "echo hi"

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "t0"}

      vault = Vaults.get_vault_by_name("alice", user.id)
      assert Vaults.decrypted_env(vault, dek) == %{"GH" => "ghp_x", "NPM" => "npm_y"}

      agent = Agents.get_agent_by_name("researcher", user.id)
      assert agent.environment_id == env.id
    end

    test "coerces numeric and boolean secret values to strings", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          vault_resource("v", %{"secrets" => %{"PORT" => 5432, "DEBUG" => true}})
        ])

      assert [%{action: :created, secrets: secrets}] = results
      assert Enum.all?(secrets, &(&1.action == :upserted))

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      vault = Vaults.get_vault_by_name("v", user.id)
      assert Vaults.decrypted_env(vault, dek) == %{"PORT" => "5432", "DEBUG" => "true"}
    end

    # chant's fountain lexicon marks resources it manages with
    # metadata."managed-by" and prunes by reading that marker back from the
    # list endpoints — bulk apply must persist spec.metadata verbatim.
    test "spec.metadata (e.g. chant's managed-by marker) survives apply", %{user: user} do
      marker = %{"managed-by" => "chant"}

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          env_resource("e", %{"metadata" => marker}),
          vault_resource("v", %{"metadata" => marker}),
          agent_resource("a", %{"metadata" => marker})
        ])

      assert Enum.all?(results, &(&1.action == :created))
      assert Environments.get_environment_by_name("e", user.id).metadata == marker
      assert Vaults.get_vault_by_name("v", user.id).metadata == marker
      assert Agents.get_agent_by_name("a", user.id).metadata == marker
    end
  end

  describe "apply_manifest/2 updates" do
    test "re-applying the same manifest writes nothing and says so", %{user: user} do
      resources = [
        env_resource("proj", %{"secrets" => %{"TOKEN" => "t0"}}),
        agent_resource("researcher", %{"environment" => "proj"})
      ]

      {:ok, _} = Manifest.apply_manifest(user.id, resources)
      {:ok, results} = Manifest.apply_manifest(user.id, resources)

      # The secret is re-encrypted on every apply, so it keeps reporting
      # `upserted` while the row it belongs to reports `unchanged`.
      assert [
               %{kind: "Environment", action: :unchanged, secrets: [%{action: :upserted}]},
               %{kind: "Agent", action: :unchanged}
             ] = results

      assert length(Environments.list_environments(user.id)) == 1
      assert length(Agents.list_agents(user.id, [])) == 1
    end

    test "a changed spec still reports updated", %{user: user} do
      {:ok, _} = Manifest.apply_manifest(user.id, [env_resource("proj")])

      {:ok, [%{kind: "Environment", action: :updated}]} =
        Manifest.apply_manifest(user.id, [env_resource("proj", %{"setup_script" => "echo hi"})])

      assert Environments.get_environment_by_name("proj", user.id).setup_script == "echo hi"
    end

    # CLAUDE.md: "Only record what happened. ... a no-op sync records nothing."
    # An apply that writes nothing must leave the trail exactly as it found it,
    # or every CI run adds a row per resource saying a record nobody touched
    # was updated.
    test "an identical re-apply writes no audit rows at all", %{user: user} do
      resources = [env_resource("proj"), agent_resource("researcher", %{"environment" => "proj"})]

      {:ok, first} = Manifest.apply_manifest(user.id, resources)
      assert Enum.all?(first, &(&1.action == :created))
      before = actions_for(user)

      {:ok, second} = Manifest.apply_manifest(user.id, resources)
      assert Enum.all?(second, &(&1.action == :unchanged))
      assert actions_for(user) == before
    end

    # Best-effort per resource means per resource. Before this, a raise in one
    # document abandoned a call that had already committed the documents above
    # it, so the caller got a 500 and no rows at all — for writes that had
    # already landed.
    test "an exception in one document fails that row and not the request", %{user: user} do
      env = insert_env(user_id: user.id, name: "proj")
      insert_agent(user_id: user.id, name: "moves")

      # Moving an agent's environment asks whether the machine it would orphan
      # is mid-turn. That is the reach outside the changeset on this path.
      stub(Fountain.Conversations, :_unsafe_homes_orphaned_by_environment, fn _a, _e ->
        raise "the sandbox provider fell over"
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, results} =
                   Manifest.apply_manifest(user.id, [
                     env_resource("proj"),
                     agent_resource("moves", %{"environment" => "proj"}),
                     agent_resource("fine", %{"environment" => "proj"})
                   ])

          assert [
                   %{kind: "Environment", action: :unchanged},
                   %{name: "moves", action: :error, errors: errors},
                   %{name: "fine", action: :created}
                 ] = results

          # The row says the pass failed and nothing more. The raised text stays
          # in the log: the environment and vault passes hold plaintext secrets
          # inside the same rescue, and an Elixir exception message embeds the
          # value it choked on.
          assert errors == %{"base" => ["apply failed unexpectedly; see the server log"]}
          refute inspect(errors) =~ "sandbox provider fell over"
        end)

      assert log =~ "sandbox provider fell over"

      # The documents above the failure stayed, and the ones below still applied.
      assert Environments.get_environment_by_name("proj", user.id).id == env.id
      assert Agents.get_agent_by_name("fine", user.id).environment_id == env.id
    end

    defp actions_for(user),
      do: user.id |> Audit.list_recent_for_user(500) |> Enum.map(& &1.action)

    test "agent can reference a pre-existing environment not in the manifest", %{user: user} do
      env = insert_env(user_id: user.id, name: "existing-env")

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          agent_resource("a", %{"environment" => "existing-env"})
        ])

      assert [%{kind: "Agent", action: :created, errors: nil}] = results
      assert Agents.get_agent_by_name("a", user.id).environment_id == env.id
    end
  end

  describe "apply_manifest/2 errors" do
    test "unknown environment reference fails that agent only", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          vault_resource("v"),
          agent_resource("a", %{"environment" => "nope"})
        ])

      assert [
               %{kind: "Vault", action: :created},
               %{kind: "Agent", name: "a", action: :error, errors: errors}
             ] = results

      assert errors == %{"environment" => ["environment not found: nope"]}
      assert Agents.get_agent_by_name("a", user.id) == nil
    end

    test "a failing resource does not stop the rest of the manifest", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          %{"kind" => "Agent", "name" => "broken", "spec" => %{"runtime" => "claude"}},
          agent_resource("ok-agent")
        ])

      assert [
               %{name: "broken", action: :error, errors: %{"model" => _}},
               %{name: "ok-agent", action: :created}
             ] = results
    end

    test "malformed resources are reported, not applied", %{user: user} do
      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          %{"kind" => "Cluster", "name" => "x"},
          %{"kind" => "Vault", "name" => ""},
          vault_resource("good")
        ])

      assert [
               %{kind: "Vault", name: "good", action: :created},
               %{kind: "Cluster", name: "x", action: :error},
               %{kind: "Vault", name: "", action: :error}
             ] = results

      assert Vaults.list_vaults(user.id) |> length() == 1
    end

    test "manifest specs cannot reassign ownership", %{user: user} do
      other = insert_verified_user()

      {:ok, [%{action: :created}]} =
        Manifest.apply_manifest(user.id, [
          vault_resource("mine", %{"user_id" => other.id, "id" => Ecto.UUID.generate()})
        ])

      assert [vault] = Vaults.list_vaults(user.id)
      assert vault.user_id == user.id
      assert Vaults.list_vaults(other.id) == []
    end
  end

  describe "apply_manifest/2 tenant isolation" do
    test "same-named resources of another tenant are not touched", %{user: user} do
      other = insert_verified_user()
      other_env = insert_env(user_id: other.id, name: "shared-name", setup_script: "original")

      {:ok, [%{kind: "Environment", action: :created}]} =
        Manifest.apply_manifest(user.id, [
          env_resource("shared-name", %{"setup_script" => "mine"})
        ])

      assert Environments.get_environment_by_name("shared-name", user.id).setup_script == "mine"
      assert Environments.get_environment!(other_env.id, other.id).setup_script == "original"
    end

    test "agent environment references cannot resolve to another tenant's environment",
         %{user: user} do
      other = insert_verified_user()
      insert_env(user_id: other.id, name: "their-env")

      {:ok, [%{kind: "Agent", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [
          agent_resource("a", %{"environment" => "their-env"})
        ])

      assert errors == %{"environment" => ["environment not found: their-env"]}
    end
  end

  describe "apply_manifest/2 the whole estate" do
    @hook_url "https://hooks.example.com/fountain"

    defp estate_manifest(vault_spec \\ %{"secrets" => %{"GH" => "ghp_x"}}) do
      # Deliberately out of order: the kinds reconcile in a fixed order,
      # whatever the file says.
      [
        webhook_resource("ci", %{
          "url" => @hook_url,
          "event_types" => ["conversation.turn.done"]
        }),
        schedule_resource("standup", %{
          "teammate" => "Ada",
          "cron" => "0 9 * * 1-5",
          "prompt" => "What is on today?"
        }),
        teammate_resource("Ada", %{
          "agent" => "ada",
          "environment" => "proj",
          "vault" => "alice"
        }),
        agent_resource("ada", %{"environment" => "proj"}),
        vault_resource("alice", vault_spec),
        env_resource("proj", %{"setup_script" => "echo hi"})
      ]
    end

    test "all six kinds apply in one request, and a second apply changes nothing",
         %{user: user} do
      inert_start_child()
      resources = estate_manifest()

      {:ok, first} = Manifest.apply_manifest(user.id, resources)

      assert Enum.map(first, &{&1.kind, &1.name, &1.action}) == [
               {"Environment", "proj", :created},
               {"Vault", "alice", :created},
               {"Agent", "ada", :created},
               {"Teammate", "Ada", :created},
               {"Schedule", "standup", :created},
               {"Webhook", "ci", :created}
             ]

      env = Environments.get_environment_by_name("proj", user.id)
      vault = Vaults.get_vault_by_name("alice", user.id)
      agent = Agents.get_agent_by_name("ada", user.id)

      assert [%{name: "Ada", agent: %{id: agent_id}, conversation: conv}] =
               Team.list_teammates(user.id)

      assert agent_id == agent.id
      assert conv.environment_id == env.id
      assert conv.vault_id == vault.id

      assert [%{name: "standup", cron: "0 9 * * 1-5", one_off: false, enabled: true}] =
               Schedules.list_schedules(user.id, agent.id)

      assert [%{url: @hook_url, event_types: ["conversation.turn.done"]}] =
               Webhooks.list_endpoints(user.id)

      {:ok, second} = Manifest.apply_manifest(user.id, resources)

      assert Enum.map(second, & &1.action) == List.duplicate(:unchanged, 6)
      assert Enum.map(second, & &1.kind) == Enum.map(first, & &1.kind)

      # Nothing was duplicated by the second pass.
      assert length(Team.list_teammates(user.id)) == 1
      assert length(Schedules.list_schedules(user.id, agent.id)) == 1
      assert length(Webhooks.list_endpoints(user.id)) == 1
    end

    test "the applied rows are audited with the request's attribution", %{user: user} do
      inert_start_child()
      opts = [actor: "api", request_ip: "203.0.113.5"]

      {:ok, _} = Manifest.apply_manifest(user.id, estate_manifest(), opts)

      events = Audit.list_recent_for_user(user.id, 200)
      actions = Enum.map(events, & &1.action)

      assert "team.member.added" in actions
      assert "team.schedule.created" in actions
      assert "webhook_endpoint.created" in actions

      for action <- ~w(team.member.added team.schedule.created webhook_endpoint.created) do
        event = Enum.find(events, &(&1.action == action))
        assert event.actor == "api", "#{action} was recorded as #{event.actor}"
        assert to_string(event.request_ip) == "203.0.113.5"
      end
    end

    # The one thing a no-op apply does write: an inline secret is encrypted
    # again every time, because the stored ciphertext cannot be compared with
    # the plaintext given.
    test "a re-apply with inline secrets writes only the secret events", %{user: user} do
      inert_start_child()
      resources = estate_manifest()

      {:ok, _} = Manifest.apply_manifest(user.id, resources)
      before = actions_for(user)

      {:ok, second} = Manifest.apply_manifest(user.id, resources)
      assert Enum.all?(second, &(&1.action == :unchanged))

      added = actions_for(user) -- before
      assert added == ["vault.secret.write"]
    end

    test "the update path is audited with the request's attribution", %{user: user} do
      inert_start_child()
      opts = [actor: "api", request_ip: "203.0.113.5"]
      {:ok, _} = Manifest.apply_manifest(user.id, estate_manifest(%{}), opts)
      before = user.id |> Audit.list_recent_for_user(500) |> length()

      moved = [
        env_resource("proj", %{"setup_script" => "echo hi"}),
        vault_resource("alice"),
        agent_resource("ada", %{"environment" => "proj"}),
        teammate_resource("Ada of proj", %{"agent" => "ada", "environment" => "proj"}),
        schedule_resource("standup", %{
          "teammate" => "Ada of proj",
          "cron" => "@daily",
          "prompt" => "What is on today?"
        }),
        webhook_resource("ci", %{"url" => @hook_url, "description" => "CI"})
      ]

      {:ok, results} = Manifest.apply_manifest(user.id, moved, opts)

      assert Enum.map(results, &{&1.kind, &1.action}) == [
               {"Environment", :unchanged},
               {"Vault", :unchanged},
               {"Agent", :unchanged},
               {"Teammate", :updated},
               {"Schedule", :updated},
               {"Webhook", :updated}
             ]

      events = Audit.list_recent_for_user(user.id, 500)
      added = Enum.take(events, length(events) - before)

      for action <- ~w(team.updated team.schedule.updated webhook_endpoint.updated) do
        event = Enum.find(added, &(&1.action == action))

        assert event,
               "the update path left no #{action}; saw #{inspect(Enum.map(added, & &1.action))}"

        assert event.actor == "api"
        assert to_string(event.request_ip) == "203.0.113.5"
      end
    end

    test "a second Teammate naming the same agent fails instead of renaming the first",
         %{user: user} do
      inert_start_child()

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          agent_resource("ada"),
          teammate_resource("Ada", %{"agent" => "ada"}),
          teammate_resource("Ada again", %{"agent" => "ada"}),
          teammate_resource("Ada", %{"agent" => "ada"})
        ])

      assert [
               %{kind: "Agent", action: :created},
               %{name: "Ada", action: :created},
               %{name: "Ada again", action: :error, errors: dup_agent},
               %{name: "Ada", action: :error, errors: dup_name}
             ] = results

      assert dup_agent == %{"agent" => ["is already claimed by another Teammate document"]}
      assert dup_name == %{"name" => ["is already used by another Teammate document"]}
      assert [%{name: "Ada"}] = Team.list_teammates(user.id)
    end

    # Without the claim check the second document renamed the first's
    # conversation on every pass, so no apply was ever `unchanged`.
    test "a manifest with a duplicate Teammate is still idempotent for the rest",
         %{user: user} do
      inert_start_child()

      resources = [
        agent_resource("ada"),
        teammate_resource("Ada", %{"agent" => "ada"}),
        teammate_resource("Ada again", %{"agent" => "ada"})
      ]

      {:ok, _} = Manifest.apply_manifest(user.id, resources)
      {:ok, second} = Manifest.apply_manifest(user.id, resources)

      assert Enum.map(second, & &1.action) == [:unchanged, :unchanged, :error]
      assert [%{name: "Ada"}] = Team.list_teammates(user.id)
    end

    test "a Teammate mid-turn on the computer it would rebind fails that row", %{user: user} do
      env = insert_env(user_id: user.id, name: "proj")
      other = insert_env(user_id: user.id, name: "other")

      agent =
        insert_agent(
          user_id: user.id,
          name: "ada",
          environment_id: other.id,
          sandbox_mode: "persistent"
        )

      home =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          mode: "persistent",
          agent_id: agent.id,
          environment_id: other.id,
          provider: "sprites"
        )

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: home,
          status: "running",
          channel_id: Team.channel()
        )

      insert_turn(conv, status: "running")

      {:ok, [%{kind: "Teammate", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [
          teammate_resource("Ada", %{"agent" => "ada", "environment" => "proj"})
        ])

      assert %{"base" => [message]} = errors
      assert message =~ "running a turn"
      assert Conversations.get_conversation(conv.id, user.id).environment_id == nil
      assert env.id
    end

    # A rebind onto an identity that already has a computer is refused rather
    # than merged onto that computer. The row says what to do about it.
    test "a Teammate rebound onto an occupied computer fails that row", %{user: user} do
      env = insert_env(user_id: user.id, name: "proj")

      agent =
        insert_agent(user_id: user.id, name: "ada", sandbox_mode: "persistent")

      home =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          mode: "persistent",
          agent_id: agent.id,
          environment_id: nil,
          provider: "sprites"
        )

      occupied =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          mode: "persistent",
          agent_id: agent.id,
          environment_id: env.id,
          provider: "sprites"
        )

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: home,
          status: "idle",
          channel_id: Team.channel()
        )

      {:ok, [%{kind: "Teammate", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [
          teammate_resource("Ada", %{"agent" => "ada", "environment" => "proj"})
        ])

      assert %{"base" => [message]} = errors
      assert message =~ "already has a computer on that environment and vault"
      assert Conversations.get_conversation(conv.id, user.id).environment_id == nil
      assert Conversations._unsafe_get_sandbox!(occupied.id).status == "ready"
    end

    test "re-applying a Teammate moves its name, environment and vault", %{user: user} do
      inert_start_child()

      {:ok, _} =
        Manifest.apply_manifest(user.id, [
          env_resource("proj"),
          vault_resource("alice"),
          agent_resource("ada"),
          teammate_resource("Ada", %{"agent" => "ada"})
        ])

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          env_resource("proj"),
          vault_resource("alice"),
          agent_resource("ada"),
          teammate_resource("Ada of proj", %{
            "agent" => "ada",
            "environment" => "proj",
            "vault" => "alice"
          })
        ])

      assert %{kind: "Teammate", name: "Ada of proj", action: :updated} =
               List.last(results)

      assert [%{name: "Ada of proj", conversation: conv}] = Team.list_teammates(user.id)
      assert conv.environment_id == Environments.get_environment_by_name("proj", user.id).id
      assert conv.vault_id == Vaults.get_vault_by_name("alice", user.id).id
    end

    # A Teammate document is the whole teammate, unlike the other five kinds,
    # where an absent spec key leaves the column alone. Dropping `environment`
    # therefore puts the teammate back on the agent's own environment.
    test "dropping a Teammate's environment and vault clears the bindings", %{user: user} do
      inert_start_child()

      bound = [
        env_resource("proj"),
        vault_resource("alice"),
        agent_resource("ada"),
        teammate_resource("Ada", %{
          "agent" => "ada",
          "environment" => "proj",
          "vault" => "alice"
        })
      ]

      {:ok, _} = Manifest.apply_manifest(user.id, bound)
      assert [%{conversation: conv}] = Team.list_teammates(user.id)
      assert conv.environment_id
      assert conv.vault_id

      unbound = List.replace_at(bound, 3, teammate_resource("Ada", %{"agent" => "ada"}))
      {:ok, results} = Manifest.apply_manifest(user.id, unbound)

      assert %{kind: "Teammate", action: :updated} = List.last(results)
      assert [%{conversation: cleared}] = Team.list_teammates(user.id)
      assert cleared.environment_id == nil
      assert cleared.vault_id == nil

      # And it settles: a third apply of the same file writes nothing.
      {:ok, again} = Manifest.apply_manifest(user.id, unbound)
      assert Enum.all?(again, &(&1.action == :unchanged))
    end

    test "a Teammate naming an unknown agent, environment or vault fails only its own row",
         %{user: user} do
      inert_start_child()

      {:ok, results} =
        Manifest.apply_manifest(user.id, [
          agent_resource("ada"),
          teammate_resource("no-agent", %{"agent" => "ghost"}),
          teammate_resource("no-env", %{"agent" => "ada", "environment" => "ghost"}),
          teammate_resource("no-vault", %{"agent" => "ada", "vault" => "ghost"}),
          teammate_resource("nameless", %{}),
          teammate_resource("Ada", %{"agent" => "ada"})
        ])

      assert [
               %{kind: "Agent", name: "ada", action: :created},
               %{name: "no-agent", action: :error, errors: agent_errors},
               %{name: "no-env", action: :error, errors: env_errors},
               %{name: "no-vault", action: :error, errors: vault_errors},
               %{name: "nameless", action: :error, errors: blank_errors},
               %{name: "Ada", action: :created}
             ] = results

      assert agent_errors == %{"agent" => ["agent not found: ghost"]}
      assert env_errors == %{"environment" => ["environment not found: ghost"]}
      assert vault_errors == %{"vault" => ["vault not found: ghost"]}
      assert blank_errors == %{"agent" => ["can't be blank"]}

      assert [%{name: "Ada"}] = Team.list_teammates(user.id)
    end

    test "a Teammate cannot resolve another tenant's agent", %{user: user} do
      other = insert_verified_user()
      insert_agent(user_id: other.id, name: "theirs")

      {:ok, [%{kind: "Teammate", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [teammate_resource("T", %{"agent" => "theirs"})])

      assert errors == %{"agent" => ["agent not found: theirs"]}
      assert Team.list_teammates(user.id) == []
    end

    test "unknown spec keys on a Teammate are rejected", %{user: user} do
      {:ok, [teammate]} =
        Manifest.apply_manifest(user.id, [
          teammate_resource("t", %{"agent" => "a", "environmnet" => "x"})
        ])

      assert teammate.errors == %{"environmnet" => ["is not a supported spec key"]}
      assert Team.list_teammates(user.id) == []
    end

    test "a Schedule naming a teammate two of them answer to fails that row", %{user: user} do
      inert_start_child()
      one = insert_agent(user_id: user.id, name: "one")
      two = insert_agent(user_id: user.id, name: "two")
      {:ok, _} = Team.add_teammate(user.id, one.id, %{"name" => "Ada"})
      {:ok, _} = Team.add_teammate(user.id, two.id, %{"name" => "Ada"})

      {:ok, [%{kind: "Schedule", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [
          schedule_resource("s", %{"teammate" => "Ada", "cron" => "@daily", "prompt" => "x"})
        ])

      assert errors == %{"teammate" => ["teammate name is not unique: Ada"]}
    end

    test "a Schedule may name a teammate the tenant already has", %{user: user} do
      inert_start_child()
      agent = insert_agent(user_id: user.id, name: "ada")
      {:ok, _} = Team.add_teammate(user.id, agent.id, %{"name" => "Ada"})

      {:ok, [%{kind: "Schedule", name: "nightly", action: :created}]} =
        Manifest.apply_manifest(user.id, [
          schedule_resource("nightly", %{
            "teammate" => "Ada",
            "cron" => "@daily",
            "prompt" => "sweep",
            "one_off" => true
          })
        ])

      assert [%{name: "nightly", one_off: true}] = Schedules.list_schedules(user.id, agent.id)
    end

    test "a Schedule naming no teammate fails only its own row", %{user: user} do
      {:ok, [good, bad]} =
        Manifest.apply_manifest(user.id, [
          vault_resource("v"),
          schedule_resource("s", %{"teammate" => "ghost", "cron" => "@daily", "prompt" => "x"})
        ])

      assert good.action == :created
      assert bad.action == :error
      assert bad.errors == %{"teammate" => ["teammate not found: ghost"]}
    end

    test "an invalid cron fails with the same error the create route gives", %{user: user} do
      inert_start_child()
      agent = insert_agent(user_id: user.id, name: "ada")
      {:ok, _} = Team.add_teammate(user.id, agent.id, %{"name" => "Ada"})

      {:ok, [%{kind: "Schedule", action: :error, errors: errors}]} =
        Manifest.apply_manifest(user.id, [
          schedule_resource("bad", %{
            "teammate" => "Ada",
            "cron" => "not a cron",
            "prompt" => "x"
          })
        ])

      {:error, changeset} =
        Schedules.create_schedule(user.id, %{
          "agent_id" => agent.id,
          "name" => "bad",
          "cron" => "not a cron",
          "prompt" => "x"
        })

      # Same content, keyed by string: an apply row's errors are string-keyed
      # whichever branch produced them.
      assert errors == Map.new(errors_on(changeset), fn {k, v} -> {to_string(k), v} end)
      assert Map.has_key?(errors, "cron")
      assert Schedules.list_schedules(user.id, agent.id) == []
    end

    test "re-applying a Schedule moves its cron, prompt, one_off and enabled", %{user: user} do
      inert_start_child()
      agent = insert_agent(user_id: user.id, name: "ada")
      {:ok, _} = Team.add_teammate(user.id, agent.id, %{"name" => "Ada"})

      apply_schedule = fn spec ->
        Manifest.apply_manifest(user.id, [
          schedule_resource("standup", Map.put(spec, "teammate", "Ada"))
        ])
      end

      {:ok, [%{action: :created}]} = apply_schedule.(%{"cron" => "@daily", "prompt" => "a"})
      {:ok, [%{action: :unchanged}]} = apply_schedule.(%{"cron" => "@daily", "prompt" => "a"})

      {:ok, [%{action: :updated}]} =
        apply_schedule.(%{
          "cron" => "0 9 * * 1-5",
          "prompt" => "b",
          "one_off" => true,
          "enabled" => false
        })

      assert [%{cron: "0 9 * * 1-5", prompt: "b", one_off: true, enabled: false}] =
               Schedules.list_schedules(user.id, agent.id)
    end

    test "unknown spec keys on a Schedule are rejected", %{user: user} do
      {:ok, [schedule]} =
        Manifest.apply_manifest(user.id, [
          schedule_resource("s", %{"teammate" => "t", "crn" => "@daily"})
        ])

      assert schedule.errors == %{"crn" => ["is not a supported spec key"]}
    end

    test "a Webhook hands back its secret once and never on update", %{user: user} do
      hook = fn spec -> [webhook_resource("ci", Map.put(spec, "url", @hook_url))] end

      {:ok, [created]} = Manifest.apply_manifest(user.id, hook.(%{}))
      assert created.action == :created
      assert String.starts_with?(created.secret, "whsec_")

      {:ok, [again]} = Manifest.apply_manifest(user.id, hook.(%{}))
      assert again.action == :unchanged
      assert again.secret == nil

      {:ok, [updated]} = Manifest.apply_manifest(user.id, hook.(%{"description" => "CI"}))
      assert updated.action == :updated
      assert updated.secret == nil

      assert [endpoint] = Webhooks.list_endpoints(user.id)
      assert endpoint.description == "CI"
      # The secret handed back on the create is still the one that signs.
      assert Webhooks.secret(endpoint) == {:ok, created.secret}
    end

    test "a Webhook is keyed by its url, not by the document name", %{user: user} do
      {:ok, [%{action: :created}]} =
        Manifest.apply_manifest(user.id, [webhook_resource("ci", %{"url" => @hook_url})])

      {:ok, [%{action: :unchanged}]} =
        Manifest.apply_manifest(user.id, [webhook_resource("renamed", %{"url" => @hook_url})])

      assert length(Webhooks.list_endpoints(user.id)) == 1
    end

    test "a Webhook the endpoint refuses fails that row only", %{user: user} do
      {:ok, [good, bad]} =
        Manifest.apply_manifest(user.id, [
          vault_resource("v"),
          webhook_resource("bad", %{"url" => "http://127.0.0.1/hook"})
        ])

      assert good.action == :created
      assert bad.action == :error
      assert Map.has_key?(bad.errors, "url")
      assert Webhooks.list_endpoints(user.id) == []
    end

    test "changing a Webhook's url leaves the old endpoint and adds a new one", %{user: user} do
      {:ok, [%{action: :created}]} =
        Manifest.apply_manifest(user.id, [webhook_resource("ci", %{"url" => @hook_url})])

      {:ok, [%{action: :created, secret: secret}]} =
        Manifest.apply_manifest(user.id, [
          webhook_resource("ci", %{"url" => "https://hooks.example.com/second"})
        ])

      assert String.starts_with?(secret, "whsec_")
      # No prune: the endpoint the old URL named is still there and still
      # delivering, and has to be deleted through its own route.
      assert length(Webhooks.list_endpoints(user.id)) == 2
    end

    test "unknown spec keys on a Webhook are rejected", %{user: user} do
      {:ok, [webhook]} =
        Manifest.apply_manifest(user.id, [
          webhook_resource("w", %{"url" => @hook_url, "status" => "disabled"})
        ])

      assert webhook.errors == %{"status" => ["is not a supported spec key"]}
      assert Webhooks.list_endpoints(user.id) == []
    end
  end
end
