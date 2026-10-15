defmodule Fountain.ManifestTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Audit, Crypto, Environments, Manifest, Vaults}

  setup do
    %{user: insert_verified_user()}
  end

  defp env_resource(name, spec \\ %{}) do
    %{"kind" => "Environment", "name" => name, "spec" => spec}
  end

  defp vault_resource(name, spec \\ %{}) do
    %{"kind" => "Vault", "name" => name, "spec" => spec}
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

      # A raise from outside the changeset on the update path: the audit write
      # for the update.
      stub(Fountain.Audit, :record_resource, fn
        "agent.updated", _type, _resource, _opts ->
          raise "the sandbox provider fell over"

        action, type, resource, opts ->
          Mimic.call_original(Fountain.Audit, :record_resource, [action, type, resource, opts])
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
    defp estate_manifest(vault_spec \\ %{"secrets" => %{"GH" => "ghp_x"}}) do
      # Deliberately out of order: the kinds reconcile in a fixed order,
      # whatever the file says.
      [
        agent_resource("ada", %{"environment" => "proj"}),
        vault_resource("alice", vault_spec),
        env_resource("proj", %{"setup_script" => "echo hi"})
      ]
    end

    test "all three kinds apply in one request, and a second apply changes nothing",
         %{user: user} do
      resources = estate_manifest()

      {:ok, first} = Manifest.apply_manifest(user.id, resources)

      assert Enum.map(first, &{&1.kind, &1.name, &1.action}) == [
               {"Environment", "proj", :created},
               {"Vault", "alice", :created},
               {"Agent", "ada", :created}
             ]

      env = Environments.get_environment_by_name("proj", user.id)
      assert Agents.get_agent_by_name("ada", user.id).environment_id == env.id

      {:ok, second} = Manifest.apply_manifest(user.id, resources)

      assert Enum.map(second, & &1.action) == List.duplicate(:unchanged, 3)
      assert Enum.map(second, & &1.kind) == Enum.map(first, & &1.kind)
    end

    # ADR 0074: the team went, and its two kinds with it.
    test "a Teammate or Schedule document is an invalid resource, and the rest apply",
         %{user: user} do
      resources =
        estate_manifest() ++
          [
            %{"kind" => "Teammate", "name" => "Ada", "spec" => %{"agent" => "ada"}},
            %{"kind" => "Schedule", "name" => "standup", "spec" => %{"teammate" => "Ada"}}
          ]

      {:ok, results} = Manifest.apply_manifest(user.id, resources)

      assert Enum.map(results, &{&1.kind, &1.action}) == [
               {"Environment", :created},
               {"Vault", :created},
               {"Agent", :created},
               {"Teammate", :error},
               {"Schedule", :error}
             ]

      assert %{"resource" => [message]} = List.last(results).errors
      assert message =~ "Environment | Vault | Agent"
    end

    test "the applied rows are audited with the request's attribution", %{user: user} do
      opts = [actor: "api", request_ip: "203.0.113.5"]

      {:ok, _} = Manifest.apply_manifest(user.id, estate_manifest(), opts)

      events = Audit.list_recent_for_user(user.id, 200)

      for action <- ~w(environment.created vault.created agent.created) do
        event = Enum.find(events, &(&1.action == action))
        assert event, "apply left no #{action}"
        assert event.actor == "api", "#{action} was recorded as #{event.actor}"
        assert to_string(event.request_ip) == "203.0.113.5"
      end
    end

    # The one thing a no-op apply does write: an inline secret is encrypted
    # again every time, because the stored ciphertext cannot be compared with
    # the plaintext given.
    test "a re-apply with inline secrets writes only the secret events", %{user: user} do
      resources = estate_manifest()

      {:ok, _} = Manifest.apply_manifest(user.id, resources)
      before = actions_for(user)

      {:ok, second} = Manifest.apply_manifest(user.id, resources)
      assert Enum.all?(second, &(&1.action == :unchanged))

      added = actions_for(user) -- before
      assert added == ["vault.secret.write"]
    end

    test "the update path is audited with the request's attribution", %{user: user} do
      opts = [actor: "api", request_ip: "203.0.113.5"]
      {:ok, _} = Manifest.apply_manifest(user.id, estate_manifest(%{}), opts)
      before = user.id |> Audit.list_recent_for_user(500) |> length()

      moved = [
        env_resource("proj", %{"setup_script" => "echo hi"}),
        vault_resource("alice"),
        agent_resource("ada", %{"environment" => "proj", "description" => "moved"})
      ]

      {:ok, results} = Manifest.apply_manifest(user.id, moved, opts)

      assert Enum.map(results, &{&1.kind, &1.action}) == [
               {"Environment", :unchanged},
               {"Vault", :unchanged},
               {"Agent", :updated}
             ]

      events = Audit.list_recent_for_user(user.id, 500)
      added = Enum.take(events, length(events) - before)
      event = Enum.find(added, &(&1.action == "agent.updated"))

      assert event,
             "the update path left no agent.updated; saw #{inspect(Enum.map(added, & &1.action))}"

      assert event.actor == "api"
      assert to_string(event.request_ip) == "203.0.113.5"
    end
  end
end
