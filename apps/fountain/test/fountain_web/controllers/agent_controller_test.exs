defmodule FountainWeb.AgentControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/agents" do
    test "returns 200 and lists user's agents", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert agent.id in ids
    end

    test "does not include agents belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_agent.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/agents")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/agents/:id" do
    test "returns 200 with the agent for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == agent.id
      assert body["data"]["name"] == agent.name
    end

    # `managoat acp` asks this before opening a session, so an editor is
    # refused a runtime whose output it could not render (#702). Deriving it
    # here rather than hardcoding a runtime list in the Go CLI is the point:
    # that list changes when a held-back runtime is converted, and a client
    # shipping a copy of it would be wrong until its next release.
    test "reports whether the runtime speaks ACP", %{conn: conn, user: user, raw_key: raw_key} do
      # gemini was the `false` case until #659 lifted its block. Every runtime
      # an agent may name now speaks ACP, so the field is true for all of them
      # — asserted across the whole vocabulary rather than dropped, because the
      # day a fifth runtime lands without an adapter this should fail here.
      for runtime <- Fountain.Agents.Agent.runtimes() do
        agent = insert_agent(user_id: user.id, runtime: runtime)
        conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{agent.id}")

        assert json_response(conn, 200)["data"]["acp"] == true,
               "expected #{runtime} to report acp: true"
      end
    end

    # A non-nullable model in the request schema made this a 400 from
    # CastAndValidate, before the changeset ever saw it, so a converted agent
    # kept a provider/model it no longer uses forever (#1634).
    test "converts an agent to acp and clears the model it no longer uses", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id, runtime: "claude")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{agent.id}", %{
          runtime: "acp",
          model: nil,
          runtime_command: "chant acp"
        })

      body = json_response(conn, 200)
      assert body["data"]["runtime"] == "acp"
      assert body["data"]["runtime_command"] == "chant acp"
      assert is_nil(body["data"]["model"])
      assert is_nil(Fountain.Agents.get_agent(agent.id, user.id).model)
    end

    test "a null model on a model-driven runtime is a 422 naming the field", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id, runtime: "claude")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{agent.id}", %{model: nil})

      assert json_response(conn, 422)["errors"]["model"] == ["can't be blank"]
    end

    test "returns 404 when the agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/agents/#{other_agent.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conn = get(conn, "/api/agents/#{agent.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/agents" do
    test "creates an agent and returns 201", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "test-bot", model: "anthropic/claude-sonnet-4-6", runtime: "claude"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 201)
      assert body["data"]["name"] == "test-bot"
      assert body["data"]["model"] == "anthropic/claude-sonnet-4-6"
      assert body["data"]["runtime"] == "claude"
      assert body["data"]["id"]
    end

    test "returns 401 without authentication", %{conn: conn} do
      payload = %{name: "test-bot", model: "anthropic/claude-sonnet-4-6", runtime: "claude"}
      conn = post_json(conn, "/api/agents", payload)
      assert json_response(conn, 401)
    end

    test "creates an acp agent from a command, with no model (#1634)", %{
      conn: conn,
      raw_key: raw_key
    } do
      payload = %{name: "converger", runtime: "acp", runtime_command: "chant acp --env prod"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 201)
      assert body["data"]["runtime"] == "acp"
      assert body["data"]["runtime_command"] == "chant acp --env prod"
      assert is_nil(body["data"]["model"])
      assert body["data"]["acp"] == true
    end

    test "returns 422 naming runtime_command when an acp agent has none", %{
      conn: conn,
      raw_key: raw_key
    } do
      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", %{name: "converger", runtime: "acp"})

      body = json_response(conn, 422)
      assert body["errors"]["runtime_command"] == ["can't be blank"]
    end

    test "returns 422 naming runtime_command when another runtime carries one", %{
      conn: conn,
      raw_key: raw_key
    } do
      payload = %{
        name: "confused",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        runtime_command: "chant acp"
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 422)
      assert [message] = body["errors"]["runtime_command"]
      assert message =~ "only the acp runtime"
    end

    test "returns 422 naming model when a model-driven runtime has none", %{
      conn: conn,
      raw_key: raw_key
    } do
      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", %{name: "modelless", runtime: "claude"})

      body = json_response(conn, 422)
      assert body["errors"]["model"] == ["can't be blank"]
    end

    test "returns 422 when a skill entry has neither content nor source", %{
      conn: conn,
      raw_key: raw_key
    } do
      # OpenApiSpex does not enforce the content/source mutual-exclusivity rule;
      # the Ecto changeset's validate_skills/1 does, so this reaches the DB layer
      # as a pure changeset error and is rendered as 422.
      payload = %{
        name: "test-bot",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        skills: [%{name: "my-skill"}]
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      assert json_response(conn, 422)
    end

    test "returns 422 when environment_id belongs to another tenant", %{
      conn: conn,
      raw_key: raw_key
    } do
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)

      payload = %{
        name: "probe",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        environment_id: victim_env.id
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 422)
      assert body["errors"]["environment_id"] == ["does not exist"]
    end

    test "accepts environment_id owned by the caller", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      payload = %{
        name: "with-env",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        environment_id: env.id
      }

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)

      body = json_response(conn, 201)
      assert body["data"]["environment_id"] == env.id
    end

    # #783: the allowlist that scopes per-launch environment overrides round-trips.
    test "accepts and reports allowed_environment_ids", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      env = insert_env(user_id: user.id)

      payload = %{
        name: "with-env-allowlist",
        model: "anthropic/claude-sonnet-4-6",
        runtime: "claude",
        allowed_environment_ids: [env.id]
      }

      body =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", payload)
        |> json_response(201)

      assert body["data"]["allowed_environment_ids"] == [env.id]
    end
  end

  describe "PUT /api/agents/:id" do
    test "updates the agent and returns 200", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{agent.id}", %{name: "updated-bot"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "updated-bot"
      assert body["data"]["id"] == agent.id
    end

    test "returns 404 when the agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{other_agent.id}", %{name: "hacked"})

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conn = put_json(conn, "/api/agents/#{agent.id}", %{name: "updated"})
      assert json_response(conn, 401)
    end

    test "returns 422 when updating environment_id to another tenant's", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{agent.id}", %{environment_id: victim_env.id})

      body = json_response(conn, 422)
      assert body["errors"]["environment_id"] == ["does not exist"]
    end
  end

  describe "DELETE /api/agents/:id" do
    test "deletes the agent and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/agents/#{agent.id}")

      assert conn.status == 204
    end

    test "returns 404 when the agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/agents/#{other_agent.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      conn = delete(conn, "/api/agents/#{agent.id}")
      assert json_response(conn, 401)
    end
  end

  describe "permission_policy over the API (#939/#940)" do
    test "POST accepts a policy and round-trips it", %{conn: conn, raw_key: raw_key} do
      # The agent is where a policy is normally set — a launch may only narrow
      # it — so this is the path that matters, and it goes through
      # CastAndValidate. A property missing from AgentRequest is invisible to
      # every generated client even when the controller would have accepted it.
      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/agents", %{
          "name" => "policy-agent",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude",
          "permission_policy" => %{"default" => "auto_allow", "Bash" => "ask"}
        })

      body = json_response(conn, 201)
      assert body["data"]["permission_policy"] == %{"default" => "auto_allow", "Bash" => "ask"}
    end

    test "PUT updates a policy", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> put("/api/agents/#{agent.id}", %{"permission_policy" => %{"Bash" => "auto_deny"}})

      body = json_response(conn, 200)
      assert body["data"]["permission_policy"] == %{"Bash" => "auto_deny"}
    end

    test "PUT with null clears the policy", %{conn: conn, user: user, raw_key: raw_key} do
      # `permission_policy` is `allOf: [PermissionPolicy], nullable: true` at
      # every call site (#1899). OpenApiSpex answers null on the wrapper's own
      # `nullable` before it dispatches to the composition, so this is the
      # casting half of "the field takes null"; the document half — that a
      # standards validator agrees — is checked in schema_guardrail_test.exs.
      # Both have to hold for a generated client to send
      # the null it is typed to send. An agent's policy is never null in
      # storage (the column is NOT NULL, default `{}`), so null clears it and
      # the response shows the empty policy; it used to be a 500 from the
      # not-null constraint.
      agent = insert_agent(user_id: user.id, permission_policy: %{"Bash" => "ask"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> put("/api/agents/#{agent.id}", %{"permission_policy" => nil})

      body = json_response(conn, 200)
      assert body["data"]["permission_policy"] == %{}
    end

    test "an unknown verdict is refused", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/agents", %{
          "name" => "bad-policy",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude",
          "permission_policy" => %{"Bash" => "banana"}
        })

      assert json_response(conn, 422)
    end
  end
end
