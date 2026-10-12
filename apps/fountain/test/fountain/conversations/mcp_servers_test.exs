defmodule Fountain.Conversations.McpServersTest do
  use Fountain.DataCase, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Conversations.McpServers
  alias Fountain.Environments.Environment

  describe "substitute_agent/3" do
    test "no agent is no agent" do
      assert {:ok, nil} = McpServers.substitute_agent(nil, nil, %{})
    end

    test "resolves ${VAR} against env vars, with secrets winning on collision" do
      agent = %Agent{mcp_servers: %{"svc" => %{"url" => "${HOST}/${TOKEN}", "port" => 1}}}
      env = %Environment{env_vars: %{"TOKEN" => "from-env", HOST: "h"}}

      assert {:ok, %Agent{mcp_servers: mcp}} =
               McpServers.substitute_agent(agent, env, %{"TOKEN" => "from-vault"})

      assert mcp == %{"svc" => %{"url" => "h/from-vault", "port" => 1}}
    end

    test "an agent with no servers passes through" do
      assert {:ok, %Agent{mcp_servers: %{}}} =
               McpServers.substitute_agent(%Agent{mcp_servers: nil}, nil, %{})
    end

    test "names every missing variable" do
      agent = %Agent{mcp_servers: %{"a" => "${B}", "c" => "${A}"}}

      assert {:error, {:missing_vars, ["A", "B"]}} =
               McpServers.substitute_agent(agent, nil, %{})
    end
  end

  describe "resolve_for_session/2 and for_session/3 (#1404)" do
    # The escape is the whole bug. `$${FOUNTAIN_TOKEN}` means "leave a literal
    # `${FOUNTAIN_TOKEN}` for the runtime to expand from the sandbox's process
    # env". Fountain's pass turns `$$` into `$`; the runtime then expands the
    # single-`$` reference. Send the *raw* document to `session/new` instead
    # and the runtime expands the inner reference and leaves the escape, so
    # the server receives `Bearer $ftn_…`.
    test "the escaped form survives exactly one pass" do
      agent = %Agent{
        mcp_servers: %{
          "salon" => %{"headers" => %{"Authorization" => "Bearer $${FOUNTAIN_TOKEN}"}}
        }
      }

      assert {:ok, %Agent{mcp_servers: resolved}} =
               McpServers.substitute_agent(agent, nil, %{})

      assert resolved == %{
               "salon" => %{"headers" => %{"Authorization" => "Bearer ${FOUNTAIN_TOKEN}"}}
             }

      # And that resolved form is what a turn puts on the wire, not the row.
      assert %Agent{mcp_servers: ^resolved} = McpServers.resolve_for_session(agent, resolved)
    end

    test "an ordinary reference resolves once, and is not expanded twice" do
      # `${A}` resolving to a string that itself looks like a reference must
      # not be re-scanned: one pass, or a secret whose value contains `${...}`
      # would reach for a variable the tenant never wrote.
      agent = %Agent{mcp_servers: %{"svc" => %{"url" => "${A}"}}}

      assert {:ok, %Agent{mcp_servers: mcp}} =
               McpServers.substitute_agent(agent, nil, %{"A" => "${B}", "B" => "leaked"})

      assert mcp == %{"svc" => %{"url" => "${B}"}}
    end

    test "the stored agent is never mutated by resolution" do
      raw = %{"svc" => %{"token" => "${SECRET}"}}
      agent = %Agent{mcp_servers: raw}

      {:ok, %Agent{mcp_servers: resolved}} =
        McpServers.substitute_agent(agent, nil, %{"SECRET" => "s3cret"})

      # The resolved value exists only on the copy the session is built from.
      assert resolved == %{"svc" => %{"token" => "s3cret"}}
      assert agent.mcp_servers == raw
    end

    test "no resolved config leaves the freshly-fetched agent alone" do
      # An agentless conversation, and one whose server has not provisioned
      # yet: return the agent untouched rather than blanking its config.
      agent = %Agent{mcp_servers: %{"svc" => %{"url" => "${A}"}}}

      assert McpServers.resolve_for_session(agent, nil) == agent
      assert McpServers.resolve_for_session(nil, %{"svc" => %{}}) == nil
    end

    # The reported case, end to end: Salon's conversation-authenticated HTTP
    # MCP server. The row holds `Bearer $${FOUNTAIN_TOKEN}`; what reaches
    # `session/new` must be the single-`$` form the runtime can expand, so the
    # server sees `Bearer ftn_…` and not `Bearer $ftn_…`.
    test "for_session sends the resolved document, not the agent row" do
      user = insert_verified_user()

      raw = %{
        "salon" => %{
          "type" => "http",
          "url" => "https://salon.example/mcp",
          "headers" => %{"Authorization" => "Bearer $${FOUNTAIN_TOKEN}"}
        }
      }

      agent = insert_agent(user_id: user.id, mcp_servers: raw)
      conv = insert_conversation(user_id: user.id, agent: agent)

      {:ok, %Agent{mcp_servers: resolved}} = McpServers.substitute_agent(agent, nil, %{})

      servers =
        McpServers.for_session(agent, conv,
          user_id: user.id,
          conversation_id: conv.id,
          callback_token: nil,
          resolved: resolved
        )

      assert %{name: "salon", headers: headers} =
               Enum.find(servers, &(&1[:name] == "salon"))

      assert headers == [%{name: "Authorization", value: "Bearer ${FOUNTAIN_TOKEN}"}]

      # The bug: the raw row would have put the escape on the wire, and the
      # runtime would have expanded the inner reference and left the `$`.
      refute inspect(servers) =~ "$${FOUNTAIN_TOKEN}"
    end
  end

  # The regression the bridge removal (ADR 0057, #2252) is actually risky for.
  # People configure tools on an *agent* that call their own application, and
  # those are not the retired request-defined bridge: they come off the agent
  # row, their `${VAR}` references resolve against the environment and vault,
  # and they are authenticated with whatever credential the tenant put in the
  # document. Deleting `caller/2` from `fountain_served/2` must not touch any
  # of that.
  describe "an agent-configured application tool survives the bridge removal" do
    setup do
      user = insert_verified_user()

      raw = %{
        "my-app" => %{
          "type" => "http",
          "url" => "${APP_HOST}/mcp",
          "headers" => %{"Authorization" => "Bearer ${APP_KEY}"}
        }
      }

      agent = insert_agent(user_id: user.id, mcp_servers: raw)
      env = %Environment{env_vars: %{"APP_HOST" => "https://app.example"}}

      {:ok, %Agent{mcp_servers: resolved}} =
        McpServers.substitute_agent(agent, env, %{"APP_KEY" => "sk-live-abc"})

      %{user: user, agent: agent, resolved: resolved}
    end

    defp session_servers(ctx, conv, token) do
      McpServers.for_session(ctx.agent, conv,
        user_id: ctx.user.id,
        conversation_id: conv.id,
        callback_token: token,
        resolved: ctx.resolved
      )
    end

    test "reaches session/new with its substituted URL and headers", ctx do
      conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent)

      assert %{name: "my-app", type: "http", url: url, headers: headers} =
               ctx |> session_servers(conv, "tok") |> Enum.find(&(&1[:name] == "my-app"))

      assert url == "https://app.example/mcp"
      assert headers == [%{name: "Authorization", value: "Bearer sk-live-abc"}]
    end

    test "is served again on a later turn on the same conversation", ctx do
      conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent)

      first = session_servers(ctx, conv, "tok")
      # A resumed turn re-reads the agent row and re-resolves; the same
      # document has to come back rather than a blanked or half-expanded one.
      second = session_servers(ctx, Fountain.Repo.reload!(conv), "tok-rotated")

      served = Enum.find(first, &(&1[:name] == "my-app"))

      # Guard the guard: two absent servers would compare equal and pass this
      # vacuously, which is exactly the regression it exists to catch.
      assert %{name: "my-app", url: "https://app.example/mcp"} = served
      assert Enum.find(second, &(&1[:name] == "my-app")) == served
    end

    test "is served with no callback token at all", ctx do
      # The Fountain-served lists are gated on the conversation credential.
      # The agent's own servers are not, and must not become so by accident.
      conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent)

      assert %{name: "my-app", url: "https://app.example/mcp"} =
               ctx |> session_servers(conv, nil) |> Enum.find(&(&1[:name] == "my-app"))
    end

    test "still comes before the team tools it shares a turn with", ctx do
      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          channel_id: Fountain.Team.channel()
        )

      names = ctx |> session_servers(conv, "tok") |> Enum.map(&(&1[:name] || &1["name"]))

      assert "my-app" in names
      assert Fountain.Team.Mcp.mcp_name() in names

      assert Enum.find_index(names, &(&1 == "my-app")) <
               Enum.find_index(names, &(&1 == Fountain.Team.Mcp.mcp_name()))
    end
  end

  describe "substitution_vars/2" do
    test "no environment is just the secrets" do
      assert McpServers.substitution_vars(nil, %{"K" => "v"}) == %{"K" => "v"}
    end

    test "env keys and values become strings; secrets override" do
      env = %Environment{env_vars: %{"K" => "env", PORT: 8080}}

      assert McpServers.substitution_vars(env, %{"K" => "secret"}) ==
               %{"PORT" => "8080", "K" => "secret"}
    end

    test "nil env_vars is an empty map" do
      assert McpServers.substitution_vars(%Environment{env_vars: nil}, %{}) == %{}
    end
  end

  describe "the Fountain-served lists without a callback token" do
    test "are empty, whatever the conversation" do
      conv = insert_conversation(channel_id: Fountain.Team.channel())

      assert McpServers.team(conv.id, nil) == []
      assert McpServers.fountain_served(conv, nil) == []
    end
  end

  describe "team/2" do
    test "serves the team tools to a conversation on the team channel only" do
      team = insert_conversation(channel_id: Fountain.Team.channel())
      other = insert_conversation()

      assert [%{name: name, type: "http", url: url, headers: [header]}] =
               McpServers.team(team.id, "tok")

      assert name == Fountain.Team.Mcp.mcp_name()
      assert String.ends_with?(url, "/api/mcp/team/" <> team.id)
      assert header == %{name: "Authorization", value: "Bearer tok"}

      assert McpServers.team(other.id, "tok") == []
    end
  end

  # ADR 0057 (#2252). #2279 stopped advertising a legacy row's persisted
  # caller tools when it removed the only controllers that could answer such a
  # call; this change removes the bridge itself, and `caller_tools` is no
  # longer a schema field at all. The guard stays: a row whose stored column
  # still holds tools must never get a `fountain-caller` server back.
  describe "a legacy row's persisted caller tools are not advertised" do
    test "a conversation map still carrying caller_tools gets no bridge server" do
      served = McpServers.fountain_served(%{id: "c1", caller_tools: [%{"name" => "x"}]}, "tok")

      assert served == []
      refute Enum.any?(served, &(&1[:name] == "fountain-caller"))
    end

    test "nor does one on the team channel, which does get its team tools" do
      conv = insert_conversation(channel_id: Fountain.Team.channel())
      legacy = %{id: conv.id, caller_tools: [%{"name" => "x"}]}

      names = legacy |> McpServers.fountain_served("tok") |> Enum.map(& &1[:name])

      # Guard the guard: the team list still arrives, so this is not an empty
      # result standing in for a correct one.
      assert Fountain.Team.Mcp.mcp_name() in names
      refute "fountain-caller" in names
    end
  end

  describe "fountain_served/2" do
    test "is the team tools on the team channel" do
      conv = insert_conversation(channel_id: Fountain.Team.channel())

      assert [%{name: team_name}] = McpServers.fountain_served(conv, "tok")

      assert team_name == Fountain.Team.Mcp.mcp_name()
    end

    test "is empty for an ordinary conversation" do
      assert McpServers.fountain_served(insert_conversation(), "tok") == []
    end

    test "is empty without a callback token" do
      # Fountain-served tools authenticate with the conversation-scoped
      # credential, or they are not served at all.
      conv = insert_conversation(channel_id: Fountain.Team.channel())

      assert McpServers.fountain_served(conv, nil) == []
    end
  end
end
