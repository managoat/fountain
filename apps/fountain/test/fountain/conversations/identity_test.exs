defmodule Fountain.Conversations.IdentityTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.Identity
  alias Fountain.InferenceCredentials
  alias Managoat.Sandbox.Session

  @conv "0b0f6e1a-4d4c-4c1a-9a2b-3c4d5e6f7a8b"
  @other "ffffffff-1111-4222-8333-444444444444"

  describe "disk_env/1" do
    test "strips the per-conversation identity and keeps everything else" do
      env = [
        {"FOUNTAIN_BASE_URL", "https://f.example"},
        {"FOUNTAIN_TOKEN", "fk_secret"},
        {"FOUNTAIN_CONVERSATION_ID", @conv},
        {"TRACEPARENT", "00-abc-def-01"},
        {"SANDBOX_URL", "https://sb.example"},
        {"GITHUB_TOKEN", "ghp_x"}
      ]

      assert Identity.disk_env(env) == [
               {"FOUNTAIN_BASE_URL", "https://f.example"},
               {"SANDBOX_URL", "https://sb.example"},
               {"GITHUB_TOKEN", "ghp_x"}
             ]
    end

    # ADR 0053 decision 4. Which credential runs a conversation is a
    # per-conversation decision and a sandbox carries several conversations
    # (ADR 0023), so a value in the shared file is a cross-conversation read
    # of whichever one provisioned last. A tenant secret of the same name is
    # not the credential and is not stripped: it belongs to the environment
    # or vault, which is what the file is for, and it is the same for every
    # conversation that attaches them.
    test "keeps every inference credential off the disk" do
      env =
        Enum.map(InferenceCredentials.env_names(), fn {_cred, name} -> {name, "value-#{name}"} end)

      assert Identity.disk_env(env) == []
    end

    test "the managed ChatGPT grant is not one of them: it never reaches the env list" do
      # ADR 0052 decision 6 keeps `CODEX_CHATGPT_ACCESS_TOKEN` out of
      # configuration entirely, so `disk_env/1` has no opinion about it and
      # must not grow one here by accident.
      refute "CODEX_CHATGPT_ACCESS_TOKEN" in Identity.process_only_keys()
    end

    test "an empty env stays empty" do
      assert Identity.disk_env([]) == []
    end

    test "keeps the broker proxy address, which carries a session token, off the disk" do
      env = [
        {"HTTPS_PROXY", "http://av_sess_x@broker.example:14322"},
        {"HTTP_PROXY", "http://av_sess_x@broker.example:14322"},
        {"https_proxy", "http://av_sess_x@broker.example:14322"},
        {"http_proxy", "http://av_sess_x@broker.example:14322"},
        {"NODE_EXTRA_CA_CERTS", "/usr/local/share/ca-certificates/agent-vault.crt"},
        {"GITHUB_TOKEN", "__github_token__"}
      ]

      assert Identity.disk_env(env) == [
               {"NODE_EXTRA_CA_CERTS", "/usr/local/share/ca-certificates/agent-vault.crt"},
               {"GITHUB_TOKEN", "__github_token__"}
             ]
    end
  end

  describe "tag_command/3" do
    test "wraps the command in env with the tag first" do
      assert Identity.tag_command(@conv, "claude-agent-acp", ["--x"]) ==
               {"env", ["FOUNTAIN_CONVERSATION_ID=#{@conv}", "claude-agent-acp", "--x"]}
    end

    test "round-trips through a provider's reported command line" do
      {cmd, args} = Identity.tag_command(@conv, "codex-acp", [])
      session = %Session{id: "1", command: Enum.join([cmd | args], " ")}
      assert Identity.conversation_id(session) == @conv
    end
  end

  describe "conversation_id/1" do
    test "reads the tag wherever it sits on the line" do
      assert Identity.conversation_id(%Session{
               id: "1",
               command: "/usr/bin/env FOUNTAIN_CONVERSATION_ID=#{@conv} gemini --acp"
             }) == @conv
    end

    test "is nil for an untagged or absent command" do
      assert Identity.conversation_id(%Session{id: "1", command: "claude-agent-acp"}) == nil
      assert Identity.conversation_id(%Session{id: "1", command: nil}) == nil
    end

    test "does not match a value that is not a uuid" do
      assert Identity.conversation_id(%Session{
               id: "1",
               command: "env FOUNTAIN_CONVERSATION_ID=nope claude-agent-acp"
             }) == nil
    end
  end

  describe "pick_session/2" do
    defp tagged(id, conv, created \\ nil) do
      %Session{
        id: id,
        command: "env FOUNTAIN_CONVERSATION_ID=#{conv} claude-agent-acp",
        created_at: created
      }
    end

    test "takes our tagged session over an earlier one tagged for another conversation" do
      assert {:tagged, %Session{id: "ours"}} =
               Identity.pick_session([tagged("theirs", @other), tagged("ours", @conv)], @conv)
    end

    test "never offers a session tagged for another conversation" do
      assert :none = Identity.pick_session([tagged("theirs", @other)], @conv)
    end

    test "never offers an untagged process, even when it is the only session" do
      legacy = %Session{id: "legacy", command: "claude-agent-acp"}

      assert :none =
               Identity.pick_session([tagged("theirs", @other), legacy], @conv)

      assert :none = Identity.pick_session([legacy], @conv)

      assert {:tagged, %Session{id: "ours"}} =
               Identity.pick_session([legacy, tagged("ours", @conv)], @conv)
    end

    test "prefers the newest of several sessions tagged for us" do
      old = tagged("old", @conv, ~U[2026-08-23 10:00:00Z])
      new = tagged("new", @conv, ~U[2026-08-23 10:05:00Z])
      assert {:tagged, %Session{id: "new"}} = Identity.pick_session([old, new], @conv)
    end

    test "an empty list is :none" do
      assert :none = Identity.pick_session([], @conv)
    end
  end
end
