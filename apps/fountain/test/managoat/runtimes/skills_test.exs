defmodule Managoat.Runtimes.SkillsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Skills
  alias Managoat.Sandbox

  setup :verify_on_exit!

  @handle %Sandbox.Handle{provider: :sprites, name: "skills-test"}

  describe "install/3" do
    test "an empty skill set is a no-op" do
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert :ok = Skills.install(@handle, [], runtime: "claude")
    end

    test "inline skills land under the runtime's skills root, in the order given" do
      test = self()

      stub(Sandbox, :write_file, fn @handle, path, body ->
        send(test, {:wrote, path, body})
        :ok
      end)

      reject(&Sandbox.exec/4)

      assert :ok =
               Skills.install(
                 @handle,
                 [
                   %{"name" => "fountain", "content" => "# API"},
                   %{name: "mine", content: "# mine"}
                 ],
                 runtime: "claude"
               )

      assert_receive {:wrote, "/home/sprite/.claude/skills/fountain/SKILL.md", "# API"}
      assert_receive {:wrote, "/home/sprite/.claude/skills/mine/SKILL.md", "# mine"}
    end

    test "the skills root follows the runtime's own HOME" do
      test = self()
      stub(Sandbox, :write_file, fn _h, path, _body -> send(test, {:wrote, path}) && :ok end)

      assert :ok =
               Skills.install(@handle, [%{"name" => "s", "content" => "c"}], runtime: "gemini")

      assert_receive {:wrote, "/tmp/.gemini/skills/s/SKILL.md"}
    end

    test "a github skill runs the skills.sh install for the runtime's agent id, before inline writes" do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", cmd], opts ->
        Agent.update(calls, &[{:exec, cmd, opts[:timeout]} | &1])
        {:ok, "", 0}
      end)

      expect(Sandbox, :write_file, fn @handle, path, _body ->
        Agent.update(calls, &[{:wrote, path} | &1])
        :ok
      end)

      assert :ok =
               Skills.install(
                 @handle,
                 [
                   %{"name" => "inline", "content" => "c"},
                   %{"source" => "owner/repo", "ref" => "v1"}
                 ],
                 runtime: Managoat.Runtimes.Codex
               )

      # The github install is listed second and runs first: a blocking exec
      # is the readiness gate the file writes need.
      assert [
               {:exec, "npx -y skills@latest add owner/repo@v1 --global --agent codex --yes",
                120_000},
               {:wrote, "/home/sprite/.codex/skills/inline/SKILL.md"}
             ] = calls |> Agent.get(& &1) |> Enum.reverse()
    end

    test "a skill that fails to land is logged, not raised, and the rest still install" do
      test = self()

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "npm ERR", 1} end)

      stub(Sandbox, :write_file, fn _h, path, _body ->
        send(test, {:wrote, path})
        if String.contains?(path, "/bad/"), do: {:error, :unavailable}, else: :ok
      end)

      assert :ok =
               Skills.install(
                 @handle,
                 [
                   %{"source" => "owner/repo"},
                   %{"name" => "bad", "content" => "c"},
                   %{"name" => "good", "content" => "c"}
                 ],
                 runtime: "claude"
               )

      assert_receive {:wrote, "/home/sprite/.claude/skills/bad/SKILL.md"}
      assert_receive {:wrote, "/home/sprite/.claude/skills/good/SKILL.md"}
    end

    test "an unknown runtime is an error, and nothing is written" do
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert {:error, msg} =
               Skills.install(@handle, [%{"name" => "s", "content" => "c"}], runtime: "nope")

      assert msg =~ "unsupported runtime"
    end
  end

  describe "github_install_cmd/2" do
    test "unpinned source installs from the default branch" do
      cmd = Skills.github_install_cmd(%{"source" => "owner/repo"}, "claude")

      assert cmd == "npx -y skills@latest add owner/repo --global --agent claude --yes"
    end

    test "ref pins the source as owner/repo@ref" do
      cmd =
        Skills.github_install_cmd(
          %{"source" => "owner/repo", "ref" => "v1.2.0"},
          "claude"
        )

      assert cmd == "npx -y skills@latest add owner/repo@v1.2.0 --global --agent claude --yes"
    end

    test "empty ref is treated as unpinned" do
      cmd = Skills.github_install_cmd(%{"source" => "owner/repo", "ref" => ""}, "claude")

      assert cmd == "npx -y skills@latest add owner/repo --global --agent claude --yes"
    end

    test "empty name does not add a skill selector" do
      cmd =
        Skills.github_install_cmd(
          %{"source" => "owner/repo", "name" => ""},
          "claude"
        )

      assert cmd == "npx -y skills@latest add owner/repo --global --agent claude --yes"
    end

    test "name adds the --skill flag alongside a ref" do
      cmd =
        Skills.github_install_cmd(
          %{"source" => "owner/repo", "ref" => "abc123", "name" => "my-skill"},
          "claude"
        )

      assert cmd ==
               "npx -y skills@latest add owner/repo@abc123 --global --agent claude --yes --skill my-skill"
    end

    test "shell-unsafe ref raises instead of reaching the command" do
      assert_raise ArgumentError, fn ->
        Skills.github_install_cmd(
          %{"source" => "owner/repo", "ref" => "main; rm -rf /"},
          "claude"
        )
      end
    end

    test "shell-unsafe source raises" do
      assert_raise ArgumentError, fn ->
        Skills.github_install_cmd(%{"source" => "owner/repo$(whoami)"}, "claude")
      end
    end
  end
end
