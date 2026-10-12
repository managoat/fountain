defmodule Fountain.Conversations.CodexSandboxTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.CodexSandbox

  test "Sprites Codex retains the conversation tag and exact argument boundaries" do
    args = ["FOUNTAIN_CONVERSATION_ID=test", "codex-acp", "argument with spaces"]

    assert CodexSandbox.command(:sprites, "codex", "env", args) ==
             {"/usr/bin/setpriv", ["--inh-caps=-all", "--ambient-caps=-all", "--", "env" | args]}
  end

  test "other providers and runtimes retain their command" do
    for provider <- [:sprites, :e2b, :runner],
        runtime <- ["codex", "claude", "gemini", "acp"],
        {provider, runtime} != {:sprites, "codex"} do
      assert CodexSandbox.command(provider, runtime, "adapter", ["--flag"]) ==
               {"adapter", ["--flag"]}
    end
  end

  @tag skip: not (File.exists?("/proc/self/status") and File.exists?("/usr/bin/setpriv"))
  test "exec clears capabilities while preserving environment, arguments and exit status" do
    script = """
    printf '%s\\n' "$FOUNTAIN_CONVERSATION_ID" "$1"
    cat /proc/self/status
    exit 42
    """

    {cmd, args} =
      CodexSandbox.command(:sprites, "codex", "env", [
        "FOUNTAIN_CONVERSATION_ID=test-conversation",
        "sh",
        "-c",
        script,
        "capability-test",
        "argument with spaces"
      ])

    assert {output, 42} = System.cmd(cmd, args, stderr_to_stdout: true)
    assert String.starts_with?(output, "test-conversation\nargument with spaces\n")

    # The Sprites agent is non-root. Root has different exec capability rules.
    unless Regex.match?(~r/^Uid:\s+0\s/m, output) do
      for key <- ["CapInh", "CapPrm", "CapEff", "CapAmb"] do
        assert Regex.match?(Regex.compile!("^#{key}:\\s+0+$", "m"), output)
      end
    end
  end
end
