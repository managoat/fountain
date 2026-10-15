defmodule Managoat.Runtimes.ClaudeTest do
  @moduledoc """
  MCP servers are provisioned into the sandbox (project `.mcp.json` + an
  auto-approve setting) because the ACP session-scoped channel is broken
  upstream (#837), and every sandbox gets the settings that keep thinking
  visible. This pins the provisioning shape, and the env `model_env/1` names.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Claude
  alias Managoat.Sandbox

  setup :set_mimic_from_context

  setup do
    Mimic.copy(Managoat.Sandbox)
    handle = %Sandbox.Handle{provider: :fake, name: "sb"}
    {:ok, handle: handle}
  end

  test "without MCP servers only the settings are written, thinking summaries on", %{
    handle: handle
  } do
    test = self()

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, path, body ->
      send(test, {:wrote, path, body})
      :ok
    end)

    for agent <- [%{mcp_servers: %{}}, %{mcp_servers: nil}, nil, %{}] do
      assert Claude.write_config(handle, agent) == :ok
      assert_receive {:wrote, "/home/sprite/.claude/settings.json", settings}
      assert Jason.decode!(settings) == %{"showThinkingSummaries" => true}
      refute_received {:wrote, "/home/sprite/.mcp.json", _}
    end
  end

  test "MCP servers are written as project .mcp.json plus the settings, auto-approving them", %{
    handle: handle
  } do
    test = self()

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, path, body ->
      send(test, {:wrote, path, body})
      :ok
    end)

    mcp = %{
      "fs" => %{
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
      }
    }

    assert Claude.write_config(handle, %{mcp_servers: mcp}) == :ok

    assert_receive {:wrote, "/home/sprite/.mcp.json", mcp_json}
    assert %{"mcpServers" => %{"fs" => %{"command" => "npx"}}} = Jason.decode!(mcp_json)

    assert_receive {:wrote, "/home/sprite/.claude/settings.json", settings}

    assert Jason.decode!(settings) == %{
             "enableAllProjectMcpServers" => true,
             "showThinkingSummaries" => true
           }
  end

  test "a transient write error is retried, then the config lands", %{handle: handle} do
    # The first filesystem call into a freshly created sprite timed out once
    # in prod and, with no retry, failed the whole provision. Both writes are
    # idempotent, so they go through Managoat.Sandbox.Retry.
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
        _ -> :ok
      end
    end)

    assert Claude.write_config(handle, %{mcp_servers: %{"fs" => %{"command" => "npx"}}}) == :ok
    assert Agent.get(calls, & &1) == 3
  end

  test "a write that keeps failing is a tagged error, not a crash", %{handle: handle} do
    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body ->
      {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
    end)

    assert {:error, {:runtime_config, "/home/sprite/.mcp.json", {:unavailable, _}}} =
             Claude.write_config(handle, %{mcp_servers: %{"fs" => %{"command" => "npx"}}})
  end

  describe "default_env/2" do
    test "prefers the oauth token over the api key" do
      env =
        Claude.default_env(nil, %{
          claude_code_oauth_token: "oauth-token",
          anthropic_api_key: "api-key"
        })

      assert env == [
               {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"},
               {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}
             ]
    end

    test "falls back to the api key when there is no oauth token" do
      env = Claude.default_env(nil, %{anthropic_api_key: "api-key"})

      assert env == [
               {"ANTHROPIC_API_KEY", "api-key"},
               {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}
             ]
    end

    test "carries only the traffic flag when neither credential is on file" do
      # The first-start delay it avoids is the CLI's, whatever the credential.
      assert Claude.default_env(nil, %{}) == [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}]
    end
  end

  describe "fall_back_to_api_key/2 (#655)" do
    test "swaps the oauth token for the api key when one is on file" do
      env = [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}, {"OTHER_VAR", "x"}]

      result = Claude.fall_back_to_api_key(env, %{anthropic_api_key: "api-key"})

      assert {"ANTHROPIC_API_KEY", "api-key"} in result
      refute List.keymember?(result, "CLAUDE_CODE_OAUTH_TOKEN", 0)
      assert {"OTHER_VAR", "x"} in result
    end

    test "leaves the env untouched when no api key is on file" do
      env = [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}]

      assert Claude.fall_back_to_api_key(env, %{}) == env
    end

    test "does not duplicate an api key entry the env already carries" do
      env = [
        {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"},
        {"ANTHROPIC_API_KEY", "stale-key"}
      ]

      result = Claude.fall_back_to_api_key(env, %{anthropic_api_key: "fresh-key"})

      assert Enum.count(result, fn {k, _v} -> k == "ANTHROPIC_API_KEY" end) == 1
      assert {"ANTHROPIC_API_KEY", "fresh-key"} in result
    end
  end

  describe "model_env/1 (the opus alias)" do
    test "points the opus alias at Opus 5 for a turn that asks for it" do
      pair = [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]
      assert Claude.model_env("claude-opus-5") == pair
      assert Claude.model_env("anthropic/claude-opus-5") == pair
    end

    test "needs nothing for any other model, or none" do
      for model <- ["claude-opus-5-5", "opus", "claude-sonnet-5", "claude-fable-5-1", nil] do
        assert Claude.model_env(model) == [], "#{inspect(model)}"
      end
    end
  end
end
