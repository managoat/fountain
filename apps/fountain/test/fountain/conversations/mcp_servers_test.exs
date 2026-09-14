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
      conv = %{conv | caller_tools: [%{"name" => "x"}]}

      assert McpServers.team(conv.id, nil) == []
      assert McpServers.caller(conv, nil) == []
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

  describe "caller/2" do
    test "serves the caller bridge when the row has tools registered" do
      conv = %{id: "c1", caller_tools: [%{"name" => "x"}]}

      assert [%{name: "fountain-caller", type: "http", url: url}] =
               McpServers.caller(conv, "tok")

      assert String.ends_with?(url, "/api/mcp/caller/c1")
      assert McpServers.caller(%{id: "c1", caller_tools: []}, "tok") == []
    end
  end

  describe "fountain_served/2" do
    test "is extensions, buzz, team, caller, in that order" do
      # No Buzz identity on this row, so that list is empty; the order of the ones that remain is the order the server
      # appended them before #1371, with installed extensions prepended by
      # #1505.
      conv = insert_conversation(channel_id: Fountain.Team.channel())
      conv = %{conv | caller_tools: [%{"name" => "x"}]}

      assert [%{name: team_name}, %{name: "fountain-caller"}] =
               McpServers.fountain_served(conv, "tok")

      assert team_name == Fountain.Team.Mcp.mcp_name()
    end

    test "is empty for an ordinary conversation" do
      assert McpServers.fountain_served(insert_conversation(), "tok") == []
    end
  end

  describe "fountain_served/2 and extensions (ADR 0043, #1505)" do
    alias Fountain.ExtensionFixtures

    test "an installed extension's servers come first, ahead of the host's own" do
      # The fixture claims one fixed conversation id, so this is the only test
      # in the suite that sees its contribution — every other conversation is a
      # fresh UUID and gets nothing.
      conv = %{
        id: ExtensionFixtures.Enabled.claimed_conversation_id(),
        caller_tools: [%{"name" => "x"}]
      }

      assert [%{"name" => "fixture"}, %{name: "fountain-caller"}] =
               McpServers.fountain_served(conv, "tok")
    end

    test "an extension contributes nothing to a conversation it does not claim" do
      conv = %{id: Ecto.UUID.generate(), caller_tools: [%{"name" => "x"}]}

      assert [%{name: "fountain-caller"}] = McpServers.fountain_served(conv, "tok")
    end

    test "a disabled extension contributes nothing even to the claimed conversation" do
      # ExtensionFixtures.Disabled returns a server unconditionally and is in
      # :extensions. If installed/0 stopped filtering, it would appear here.
      conv = %{id: ExtensionFixtures.Enabled.claimed_conversation_id(), caller_tools: []}

      names = conv |> McpServers.fountain_served("tok") |> Enum.map(& &1["name"])
      refute "disabled-should-never-appear" in names
    end

    test "extensions are not consulted without a callback token" do
      # The whole list is gated on the conversation-scoped credential: an
      # extension's servers are authenticated with it or they are not served.
      conv = %{id: ExtensionFixtures.Enabled.claimed_conversation_id(), caller_tools: []}

      assert McpServers.fountain_served(conv, nil) == []
    end
  end
end
