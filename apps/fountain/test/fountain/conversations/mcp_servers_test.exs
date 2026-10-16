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
    # The escape is the whole bug. `$${MANAGOAT_TOKEN}` means "leave a literal
    # `${MANAGOAT_TOKEN}` for the runtime to expand from the sandbox's process
    # env". Fountain's pass turns `$$` into `$`; the runtime then expands the
    # single-`$` reference. Send the *raw* document to `session/new` instead
    # and the runtime expands the inner reference and leaves the escape, so
    # the server receives `Bearer $ftn_…`.
    test "the escaped form survives exactly one pass" do
      agent = %Agent{
        mcp_servers: %{
          "salon" => %{"headers" => %{"Authorization" => "Bearer $${MANAGOAT_TOKEN}"}}
        }
      }

      assert {:ok, %Agent{mcp_servers: resolved}} =
               McpServers.substitute_agent(agent, nil, %{})

      assert resolved == %{
               "salon" => %{"headers" => %{"Authorization" => "Bearer ${MANAGOAT_TOKEN}"}}
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
    # MCP server. The row holds `Bearer $${MANAGOAT_TOKEN}`; what reaches
    # `session/new` must be the single-`$` form the runtime can expand, so the
    # server sees `Bearer ftn_…` and not `Bearer $ftn_…`.
    test "for_session sends the resolved document, not the agent row" do
      user = insert_verified_user()

      raw = %{
        "salon" => %{
          "type" => "http",
          "url" => "https://salon.example/mcp",
          "headers" => %{"Authorization" => "Bearer $${MANAGOAT_TOKEN}"}
        }
      }

      agent = insert_agent(user_id: user.id, mcp_servers: raw)

      {:ok, %Agent{mcp_servers: resolved}} = McpServers.substitute_agent(agent, nil, %{})

      servers = McpServers.for_session(agent, resolved: resolved)

      assert %{name: "salon", headers: headers} =
               Enum.find(servers, &(&1[:name] == "salon"))

      assert headers == [%{name: "Authorization", value: "Bearer ${MANAGOAT_TOKEN}"}]

      # The bug: the raw row would have put the escape on the wire, and the
      # runtime would have expanded the inner reference and left the `$`.
      refute inspect(servers) =~ "$${MANAGOAT_TOKEN}"
    end
  end

  # The regression the bridge removal (ADR 0057, #2252) is actually risky for.
  # People configure tools on an *agent* that call their own application, and
  # those are not the retired request-defined bridge: they come off the agent
  # row, their `${VAR}` references resolve against the environment and vault,
  # and they are authenticated with whatever credential the tenant put in the
  # document. Removing the Fountain-served lists must not touch any of that.
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

    test "reaches session/new with its substituted URL and headers", ctx do
      assert %{name: "my-app", type: "http", url: url, headers: headers} =
               ctx.agent
               |> McpServers.for_session(resolved: ctx.resolved)
               |> Enum.find(&(&1[:name] == "my-app"))

      assert url == "https://app.example/mcp"
      assert headers == [%{name: "Authorization", value: "Bearer sk-live-abc"}]
    end
  end

  describe ~s["auth": "conversation" (ADR 0086)] do
    @salon %{
      "type" => "http",
      "url" => "https://salon.example/mcp",
      "auth" => "conversation",
      "headers" => %{"x-managoat-conversation-id" => "spoofed", "X-Room" => "r1"}
    }

    @conversation %{id: "11111111-1111-1111-1111-111111111111", token: "ftn_live"}

    test "for_session puts the conversation's bearer and id on the entry, and nothing else" do
      agent = %Agent{
        mcp_servers: %{"salon" => @salon, "other" => %{"type" => "http", "url" => "u"}}
      }

      servers = McpServers.for_session(agent, resolved: nil, conversation: @conversation)

      assert %{name: "salon", type: "http", headers: headers} =
               salon = Enum.find(servers, &(&1.name == "salon"))

      refute Map.has_key?(salon, :auth)

      assert headers == [
               %{name: "Authorization", value: "Bearer ftn_live"},
               %{name: "X-Managoat-Conversation-Id", value: @conversation.id},
               %{name: "X-Room", value: "r1"}
             ]

      # A server that did not ask gets neither.
      assert %{name: "other"} = other = Enum.find(servers, &(&1.name == "other"))
      refute Map.has_key?(other, :headers)

      # The agent value itself is untouched.
      assert agent.mcp_servers["salon"] == @salon
    end

    test "with no callback key, the id goes and Authorization does not" do
      agent = %Agent{mcp_servers: %{"salon" => @salon}}

      for conversation <- [
            %{id: @conversation.id, token: nil},
            %{id: @conversation.id, token: ""}
          ] do
        [%{headers: headers}] = McpServers.for_session(agent, conversation: conversation)
        refute Enum.any?(headers, &(&1.name == "Authorization"))
        assert %{name: "X-Managoat-Conversation-Id", value: @conversation.id} in headers
      end
    end

    test "for_disk leaves the entry out" do
      agent = %Agent{mcp_servers: %{"salon" => @salon, "fs" => %{"command" => "npx"}}}

      assert McpServers.for_disk(agent).mcp_servers == %{"fs" => %{"command" => "npx"}}
      assert McpServers.for_disk(nil) == nil
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
end
