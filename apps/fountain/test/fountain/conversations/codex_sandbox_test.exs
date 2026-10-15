defmodule Fountain.Conversations.CodexSandboxTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.CodexSandbox

  test "Sprites Codex retains the conversation tag and exact argument boundaries" do
    args = ["MANAGOAT_CONVERSATION_ID=test", "codex-acp", "argument with spaces"]

    assert CodexSandbox.command(:sprites, "codex", "env", args) ==
             {"/usr/bin/setpriv", ["--inh-caps=-all", "--ambient-caps=-all", "--", "env" | args]}
  end

  test "other providers and runtimes retain their command" do
    for provider <- [:sprites, :e2b],
        runtime <- ["codex", "claude", "gemini", "acp"],
        {provider, runtime} != {:sprites, "codex"} do
      assert CodexSandbox.command(provider, runtime, "adapter", ["--flag"]) ==
               {"adapter", ["--flag"]}
    end
  end

  # What the wrapper does inside a sprite is checked against a real one, in
  # test/live/sandbox_sprites_live_test.exs: a host-side exec tests the CI
  # host, not the Sprites image (#1703).
end
