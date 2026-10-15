defmodule Managoat.Runtimes.InstructionsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Instructions

  setup :verify_on_exit!

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "fountain-test"}

  test "each ACP runtime has a user-level instructions file; unknown runtimes none" do
    assert Instructions.path("claude") == "/home/sprite/.claude/CLAUDE.md"
    assert Instructions.path("codex") == "/home/sprite/.codex/AGENTS.md"

    # Under the runtime's *own* HOME, which is /tmp for gemini. The earlier
    # version of this test asserted /home/sprite for it — the same wrong
    # answer the code gave, so it pinned the bug instead of catching it.
    # `Managoat.Runtimes.LayoutTest` now checks the agreement rather than the
    # literal.
    assert Instructions.path("gemini") == "/tmp/.gemini/GEMINI.md"

    assert Instructions.path("nope") == nil
    assert Instructions.path(nil) == nil
  end

  test "writes the prompt verbatim, with a provenance header, to the runtime's file" do
    expect(Managoat.Sandbox.Sprites, :write_file, fn @handle,
                                                     "/home/sprite/.claude/CLAUDE.md",
                                                     body,
                                                     _opts ->
      assert body =~ ~s(agent "team-lead")
      assert body =~ "You are team-lead, Jake's single point of contact."
      assert String.ends_with?(body, "contact.\n")
      :ok
    end)

    assert :ok =
             Instructions.write(@handle, "claude", %{
               name: "team-lead",
               system: "You are team-lead, Jake's single point of contact.\n\n"
             })
  end

  test "a blank or missing prompt writes nothing" do
    reject(&Managoat.Sandbox.Sprites.write_file/4)
    assert :ok = Instructions.write(@handle, "claude", %{name: "x", system: "   \n"})
    assert :ok = Instructions.write(@handle, "claude", %{name: "x", system: nil})
    assert :ok = Instructions.write(@handle, "claude", nil)
    assert :ok = Instructions.write(@handle, "unknown-runtime", %{name: "x", system: "hi"})
  end

  test "a refused write is reported, not raised" do
    expect(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _b, _o -> {:error, :boom} end)
    assert {:error, :boom} = Instructions.write(@handle, "codex", %{name: "x", system: "hi"})
  end
end
