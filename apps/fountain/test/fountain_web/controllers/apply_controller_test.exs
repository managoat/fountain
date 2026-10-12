defmodule FountainWeb.ApplyControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Agents, Crypto, Environments, Team, Vaults}
  alias Fountain.Team.Schedules

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "POST /api/apply — a sandbox token" do
    test "may apply a manifest", %{conn: conn, user: user} do
      {_key, sprite_key} = insert_sprite_api_key(user)

      payload = %{
        "resources" => [
          %{"kind" => "Environment", "name" => "proj", "spec" => %{"setup_script" => "echo hi"}}
        ]
      }

      conn = conn |> authed_with_key(sprite_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => [%{"action" => "created"}]}} = json_response(conn, 200)
      assert [_] = Fountain.Environments.list_environments(user.id)
    end

    test "cannot apply a Webhook, which is no longer a kind", %{conn: conn, user: user} do
      {_key, sprite_key} = insert_sprite_api_key(user)

      payload = %{
        "resources" => [
          %{
            "kind" => "Webhook",
            "name" => "ops",
            "spec" => %{"url" => "https://example.test/hook"}
          }
        ]
      }

      conn = conn |> authed_with_key(sprite_key) |> post_json(~p"/api/apply", payload)
      assert conn.status == 422
    end
  end

  describe "POST /api/apply" do
    test "an Agent naming an environment rather than an id fails that row (#1679)", %{
      conn: conn,
      raw_key: raw_key
    } do
      payload = %{
        "resources" => [
          %{
            "kind" => "Agent",
            "name" => "prod-steward",
            "spec" => %{
              "model" => "anthropic/claude-sonnet-4-6",
              "runtime" => "claude",
              "environment_id" => "toolchain"
            }
          }
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => [row]}} = json_response(conn, 200)
      assert row["action"] == "error"

      assert row["errors"]["environment_id"] == [
               ~s(must be an id, but "toolchain" is not one)
             ]
    end

    test "an Agent naming a vault rather than an id fails that row, not the request (#1679)", %{
      conn: conn,
      raw_key: raw_key
    } do
      payload = %{
        "resources" => [
          %{
            "kind" => "Vault",
            "name" => "prod-creds",
            "spec" => %{"secrets" => %{"GH" => "ghp_x"}}
          },
          %{
            "kind" => "Agent",
            "name" => "prod-steward",
            "spec" => %{
              "model" => "anthropic/claude-sonnet-4-6",
              "runtime" => "claude",
              "allowed_vault_ids" => ["prod-creds"]
            }
          }
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => results}} = json_response(conn, 200)

      assert [
               %{"kind" => "Vault", "name" => "prod-creds", "action" => "created"},
               %{"kind" => "Agent", "name" => "prod-steward", "action" => "error"} = agent_row
             ] = results

      assert agent_row["errors"]["allowed_vault_ids"] == [
               ~s(must be a list of ids, but "prod-creds" is not one)
             ]
    end

    test "applies a full manifest in one request", %{conn: conn, user: user, raw_key: raw_key} do
      payload = %{
        "resources" => [
          %{
            "kind" => "Environment",
            "name" => "proj",
            "spec" => %{"setup_script" => "echo hi", "secrets" => %{"TOKEN" => "t0"}}
          },
          %{
            "kind" => "Vault",
            "name" => "alice",
            "spec" => %{"secrets" => %{"GH" => "ghp_x"}}
          },
          %{
            "kind" => "Agent",
            "name" => "researcher",
            "spec" => %{
              "model" => "anthropic/claude-sonnet-4-6",
              "runtime" => "claude",
              "environment" => "proj"
            }
          }
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => results}} = json_response(conn, 200)

      assert [
               %{
                 "kind" => "Environment",
                 "name" => "proj",
                 "action" => "created",
                 "errors" => nil,
                 "secrets" => [%{"key" => "TOKEN", "action" => "upserted"}]
               },
               %{"kind" => "Vault", "name" => "alice", "action" => "created"},
               %{"kind" => "Agent", "name" => "researcher", "action" => "created"}
             ] = results

      env = Environments.get_environment_by_name("proj", user.id)
      assert env.setup_script == "echo hi"
      assert Agents.get_agent_by_name("researcher", user.id).environment_id == env.id

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert Environments.decrypted_env(env, dek) == %{"TOKEN" => "t0"}

      assert Vaults.decrypted_env(Vaults.get_vault_by_name("alice", user.id), dek) == %{
               "GH" => "ghp_x"
             }
    end

    test "reports unknown spec keys per resource without applying them", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      payload = %{
        "resources" => [
          %{
            "kind" => "Environment",
            "name" => "locked",
            "spec" => %{
              "network_policy" => "limited",
              "allowed_hosts" => ["example.test"],
              "secrets" => %{"TOKEN" => "not-for-the-response"}
            }
          },
          %{"kind" => "Vault", "name" => "valid", "spec" => %{}}
        ]
      }

      response = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)
      assert %{"data" => %{"results" => [bad, good]}} = json_response(response, 200)
      assert bad["action"] == "error"

      assert bad["errors"] == %{
               "network_policy" => ["is not a supported spec key"],
               "allowed_hosts" => ["is not a supported spec key"]
             }

      assert good["action"] == "created"
      refute response.resp_body =~ "not-for-the-response"
      refute Environments.get_environment_by_name("locked", user.id)
      assert Vaults.get_vault_by_name("valid", user.id)
    end

    test "reconciles the team kinds in one request", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      # Adding a teammate opens its conversation, which provisions its computer.
      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      payload = %{
        "resources" => [
          %{"kind" => "Environment", "name" => "proj", "spec" => %{}},
          %{"kind" => "Vault", "name" => "alice", "spec" => %{}},
          %{
            "kind" => "Agent",
            "name" => "ada",
            "spec" => %{"model" => "anthropic/claude-sonnet-4-6", "runtime" => "claude"}
          },
          %{
            "kind" => "Teammate",
            "name" => "Ada",
            "spec" => %{"agent" => "ada", "environment" => "proj", "vault" => "alice"}
          },
          %{
            "kind" => "Schedule",
            "name" => "standup",
            "spec" => %{"teammate" => "Ada", "cron" => "0 9 * * 1-5", "prompt" => "morning"}
          }
        ]
      }

      response = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)
      assert %{"data" => %{"results" => results}} = json_response(response, 200)

      assert Enum.map(results, &{&1["kind"], &1["action"]}) == [
               {"Environment", "created"},
               {"Vault", "created"},
               {"Agent", "created"},
               {"Teammate", "created"},
               {"Schedule", "created"}
             ]

      agent = Agents.get_agent_by_name("ada", user.id)
      assert [%{name: "Ada"}] = Team.list_teammates(user.id)
      assert [%{name: "standup"}] = Schedules.list_schedules(user.id, agent.id)

      # A second apply writes nothing.
      second =
        build_conn() |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => rows}} = json_response(second, 200)
      assert Enum.map(rows, & &1["action"]) == List.duplicate("unchanged", 5)
    end

    test "never echoes secret values back", %{conn: conn, raw_key: raw_key} do
      payload = %{
        "resources" => [
          %{"kind" => "Vault", "name" => "v", "spec" => %{"secrets" => %{"GH" => "sekrit-value"}}}
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert json_response(conn, 200)
      refute conn.resp_body =~ "sekrit-value"
    end

    test "re-apply reports unchanged, and a changed spec reports updated", %{
      conn: conn,
      raw_key: raw_key
    } do
      payload = %{
        "resources" => [%{"kind" => "Vault", "name" => "v", "spec" => %{}}]
      }

      auth = fn conn -> authed_with_key(conn, raw_key) end

      assert %{"data" => %{"results" => [%{"action" => "created"}]}} =
               conn |> auth.() |> post_json(~p"/api/apply", payload) |> json_response(200)

      assert %{"data" => %{"results" => [%{"action" => "unchanged"}]}} =
               build_conn() |> auth.() |> post_json(~p"/api/apply", payload) |> json_response(200)

      moved = %{
        "resources" => [
          %{"kind" => "Vault", "name" => "v", "spec" => %{"description" => "moved"}}
        ]
      }

      assert %{"data" => %{"results" => [%{"action" => "updated"}]}} =
               build_conn() |> auth.() |> post_json(~p"/api/apply", moved) |> json_response(200)
    end

    test "returns 200 with per-resource errors on partial failure", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      payload = %{
        "resources" => [
          %{"kind" => "Vault", "name" => "ok", "spec" => %{}},
          %{"kind" => "Agent", "name" => "broken", "spec" => %{"runtime" => "claude"}}
        ]
      }

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)

      assert %{"data" => %{"results" => [vault_result, agent_result]}} = json_response(conn, 200)
      assert vault_result["action"] == "created"
      assert agent_result["action"] == "error"
      assert %{"model" => _} = agent_result["errors"]
      assert Vaults.get_vault_by_name("ok", user.id)
      refute Agents.get_agent_by_name("broken", user.id)
    end

    test "rejects an invalid kind with 422", %{conn: conn, raw_key: raw_key} do
      payload = %{"resources" => [%{"kind" => "Cluster", "name" => "x", "spec" => %{}}]}

      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", payload)
      assert conn.status == 422
    end

    test "rejects a payload without resources with 422", %{conn: conn, raw_key: raw_key} do
      conn = conn |> authed_with_key(raw_key) |> post_json(~p"/api/apply", %{})
      assert conn.status == 422
    end

    test "requires authentication", %{conn: conn} do
      conn = post_json(conn, ~p"/api/apply", %{"resources" => []})
      assert conn.status == 401
    end
  end
end
