defmodule Managoat.Runtimes.LayoutTest do
  @moduledoc """
  The layout table, and the agreement it exists to enforce.

  The interesting tests here are the last two: they walk every runtime and
  check that the HOME the process is given and the HOME its files are written
  under are the same directory. That disagreement is what shipped — gemini
  (and the since-removed opencode) ran with `HOME=/tmp` while their system
  prompts were written to `/home/sprite`, so both ran on the CLI's default
  persona and nothing said so.
  """
  use ExUnit.Case, async: true

  alias Managoat.Runtimes
  alias Managoat.Runtimes.Instructions
  alias Managoat.Runtimes.Layout

  test "every runtime in the dispatcher has a layout row, and vice versa" do
    assert Layout.runtimes() == ["claude", "codex", "gemini"]

    for runtime <- Layout.runtimes() do
      assert {:ok, _mod} = Runtimes.for_runtime(runtime)
    end
  end

  test "paths are derived from home and config_dir" do
    assert Layout.config_root("claude") == "/home/sprite/.claude"
    assert Layout.skills_root("claude") == "/home/sprite/.claude/skills"
    assert Layout.instructions_path("claude") == "/home/sprite/.claude/CLAUDE.md"

    assert Layout.config_root("codex") == "/home/sprite/.codex"
    assert Layout.skills_root("codex") == "/home/sprite/.codex/skills"
    assert Layout.instructions_path("codex") == "/home/sprite/.codex/AGENTS.md"

    # HOME=/tmp for gemini — the paths follow it.
    assert Layout.config_root("gemini") == "/tmp/.gemini"
    assert Layout.skills_root("gemini") == "/tmp/.gemini/skills"
    assert Layout.instructions_path("gemini") == "/tmp/.gemini/GEMINI.md"
  end

  test "an unknown runtime has no layout rather than a plausible-looking one" do
    for f <- [:home, :config_root, :skills_root, :instructions_path, :cwd, :skills_sh_agent] do
      assert apply(Layout, f, ["nope"]) == nil
    end

    assert Layout.home_env("nope") == []
  end

  test "home_env exports HOME only where it differs from the image's own" do
    assert Layout.home_env("claude") == []
    assert Layout.home_env("codex") == []
    assert Layout.home_env("gemini") == [{"HOME", "/tmp"}]
  end

  test "the workspace an agent runs in is the one its layout names" do
    assert Layout.cwd("claude") == "/home/sprite"
    assert Layout.cwd("codex") == "/home/sprite"
    assert Layout.cwd("gemini") == "/tmp/gemini-workspace"

    # ACP hands this to the agent in `session/new`; it must not have drifted
    # back into a second copy.
    for runtime <- Layout.runtimes() do
      assert Managoat.Runtimes.ACP.cwd(runtime) == Layout.cwd(runtime)
    end
  end

  describe "the HOME a runtime gets and the HOME its files go under" do
    test "agree, for every runtime" do
      for runtime <- Layout.runtimes() do
        {:ok, mod} = Runtimes.for_runtime(runtime)

        # No credentials on file, so whatever is left is the layout's doing.
        exported =
          case List.keyfind(mod.default_env(nil, %{}), "HOME", 0) do
            {"HOME", home} -> home
            nil -> "/home/sprite"
          end

        assert exported == Layout.home(runtime),
               "#{runtime} runs with HOME=#{exported} but its layout says #{Layout.home(runtime)}"
      end
    end

    test "so every provisioned path sits under the runtime's own HOME" do
      for runtime <- Layout.runtimes() do
        {:ok, mod} = Runtimes.for_runtime(runtime)
        home = Layout.home(runtime)

        for {what, path} <- [
              skills_root: mod.skills_root(),
              instructions: Instructions.path(runtime)
            ] do
          assert String.starts_with?(path, home <> "/"),
                 "#{runtime}'s #{what} is #{path}, which is not under HOME=#{home}"
        end
      end
    end
  end

  test "runtime modules answer from the table rather than their own copy" do
    for runtime <- Layout.runtimes() do
      {:ok, mod} = Runtimes.for_runtime(runtime)
      assert mod.skills_root() == Layout.skills_root(runtime)
      assert mod.skills_sh_agent() == Layout.skills_sh_agent(runtime)
    end
  end
end
