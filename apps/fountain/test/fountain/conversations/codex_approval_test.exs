defmodule Fountain.Conversations.CodexApprovalTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.CodexApproval

  @asking [{"INITIAL_AGENT_MODE", "read-only"}]

  describe "asks?/1" do
    test "any verdict other than auto_allow asks" do
      assert CodexApproval.asks?(%{"default" => "ask"})
      assert CodexApproval.asks?(%{"default" => "auto_allow", "fetch" => "auto_deny"})
      assert CodexApproval.asks?(%{"default" => "auto_allow", "Bash" => "ask"})
    end

    test "a policy that allows everything, or none at all, does not" do
      refute CodexApproval.asks?(%{"default" => "auto_allow"})
      refute CodexApproval.asks?(%{"default" => "auto_allow", "execute" => "auto_allow"})
      refute CodexApproval.asks?(%{})
      refute CodexApproval.asks?(nil)
    end

    test "a value that is not a verdict asks, as the peer denies it" do
      assert CodexApproval.asks?(%{"default" => "maybe"})
    end
  end

  describe "env/2" do
    test "codex under a policy that asks gets the asking mode" do
      assert CodexApproval.env("codex", %{"default" => "ask"}) == @asking
    end

    test "codex under an allowing policy, and every other runtime, get nothing" do
      assert CodexApproval.env("codex", %{"default" => "auto_allow"}) == []
      assert CodexApproval.env("claude", %{"default" => "ask"}) == []
      assert CodexApproval.env("gemini", %{"default" => "ask"}) == []
    end
  end

  describe "put_env/2" do
    test "the asking mode replaces an environment's own mode, full access included" do
      env = [
        {"A", "1"},
        {"INITIAL_AGENT_MODE", "agent-full-access"},
        {"INITIAL_AGENT_MODE", "agent"}
      ]

      assert CodexApproval.put_env(env, @asking) == [{"A", "1"} | @asking]
    end

    test "with nothing to add, the environment's own mode stands" do
      env = [{"INITIAL_AGENT_MODE", "agent-full-access"}]
      assert CodexApproval.put_env(env, []) == env
    end
  end
end
