defmodule Fountain.SandboxSkillsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.SandboxSkills

  setup :verify_on_exit!

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "skills-test"}

  test "bundled/0 is the API skill then the team set-up skill, read from priv" do
    assert [
             %{"name" => "fountain", "content" => api},
             %{"name" => "create-team", "content" => team}
           ] =
             SandboxSkills.bundled()

    assert api =~ "FOUNTAIN_CONVERSATION_ID"
    assert team =~ "team"
  end

  test "mount/3 prepends the bundled skills to the agent's own and installs through the library" do
    test = self()

    stub(Managoat.Sandbox, :write_file, fn @handle, path, _body ->
      send(test, {:wrote, path})
      :ok
    end)

    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok = SandboxSkills.mount(@handle, "claude", [%{"name" => "mine", "content" => "# m"}])

    assert_receive {:wrote, "/home/sprite/.claude/skills/fountain/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/create-team/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/mine/SKILL.md"}
  end

  # #1634: the string used to be forwarded to the library's own dispatcher,
  # which is a closed map of the four LLM runtimes. It answered
  # {:error, "unsupported runtime: acp"} and the sandbox came up with no
  # skills at all, silently.
  test "mount/3 resolves the acp runtime through Fountain.RuntimeDispatch" do
    test = self()

    stub(Managoat.Sandbox, :write_file, fn @handle, path, _body ->
      send(test, {:wrote, path})
      :ok
    end)

    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok = SandboxSkills.mount(@handle, "acp", [%{"name" => "mine", "content" => "# m"}])

    root = Fountain.CommandRuntime.skills_root()
    assert_receive {:wrote, ^root <> "/fountain/SKILL.md"}
    assert_receive {:wrote, ^root <> "/create-team/SKILL.md"}
    assert_receive {:wrote, ^root <> "/mine/SKILL.md"}
  end

  test "a module is passed straight through to the library" do
    test = self()
    stub(Managoat.Sandbox, :write_file, fn _h, path, _b -> send(test, {:wrote, path}) && :ok end)
    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok = SandboxSkills.mount(@handle, Fountain.CommandRuntime, nil)
    assert_receive {:wrote, "/home/sprite/.claude/skills/fountain/SKILL.md"}
  end

  test "a runtime nothing implements is logged and returned, never silent" do
    reject(&Managoat.Sandbox.write_file/3)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, reason} = SandboxSkills.mount(@handle, "nonesuch", [])
        assert reason =~ "unsupported runtime"
      end)

    assert log =~ "skills not mounted for runtime nonesuch"
  end

  test "a nil skills list mounts the bundled skills alone" do
    test = self()
    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    stub(Managoat.Sandbox, :write_file, fn _h, path, _b ->
      assert path in [
               "/home/sprite/.codex/skills/fountain/SKILL.md",
               "/home/sprite/.codex/skills/create-team/SKILL.md",
               "/home/sprite/.codex/skills/.fountain-managed-skills"
             ]

      send(test, {:wrote, path})
      :ok
    end)

    assert :ok = SandboxSkills.mount(@handle, "codex", nil)
    assert_receive {:wrote, "/home/sprite/.codex/skills/fountain/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.codex/skills/create-team/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.codex/skills/.fountain-managed-skills"}
  end

  defmodule DiskRuntime do
    @moduledoc """
    A runtime whose skills root is a real directory on this machine, so the
    reconciliation can be measured against a filesystem rather than a mock.
    """
    def skills_root, do: Process.get(:skills_test_root)
    def skills_sh_agent, do: "claude"
  end

  describe "reconciliation on disk" do
    setup do
      root = Fountain.TmpDir.mkdir!("fountain-skills")
      Process.put(:skills_test_root, root)

      stub(Managoat.Sandbox, :write_file, fn _, path, content ->
        File.mkdir_p!(Path.dirname(path))
        File.write(path, content)
      end)

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
        {:ok, output, code}
      end)

      %{root: root}
    end

    test "mount_fresh/3 leaves an empty root exactly as mount/3 does, with no exec", %{
      root: root
    } do
      skills = [%{"name" => "mine", "content" => "# m"}]
      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, skills)
      reconciled = snapshot(root)

      File.rm_rf!(root)
      File.mkdir_p!(root)
      reject(&Managoat.Sandbox.exec/4)

      assert :ok = SandboxSkills.mount_fresh(@handle, DiskRuntime, skills)
      assert snapshot(root) == reconciled
      assert Map.has_key?(reconciled, ".fountain-managed-skills")
    end

    test "mount_fresh/3 reconciles when a skill is remote", %{root: root} do
      test = self()

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        send(test, :exec)
        {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
        {:ok, output, code}
      end)

      assert :ok =
               SandboxSkills.mount_fresh(@handle, DiskRuntime, [
                 %{"source" => "owner/repo", "name" => "remote"}
               ])

      assert_received :exec
      assert File.exists?(Path.join(root, "fountain/SKILL.md"))
    end

    test "removes an obsolete inline skill while preserving unrelated files", %{root: root} do
      File.mkdir_p!(Path.join(root, "personal"))
      File.write!(Path.join(root, "personal/SKILL.md"), "My local skill")

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [
                 %{"name" => "old", "content" => "Old skill"}
               ])

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [
                 %{"name" => "new", "content" => "New skill"}
               ])

      refute File.exists?(Path.join(root, "old"))
      assert File.read!(Path.join(root, "new/SKILL.md")) == "New skill"
      # Not Fountain's, so not Fountain's to delete.
      assert File.read!(Path.join(root, "personal/SKILL.md")) == "My local skill"
      assert File.exists?(Path.join(root, "fountain/SKILL.md"))
    end

    test "repeating a legacy reconciliation keeps the manifest and unrelated files", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      File.mkdir_p!(Path.join(root, "personal"))
      File.write!(Path.join(root, "personal/SKILL.md"), "Keep my work")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]
      selected = [%{"name" => "current", "content" => "Current skill"}]

      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, selected, previous)
      manifest = File.read!(Path.join(root, ".fountain-managed-skills"))
      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, selected, previous)
      assert File.read!(Path.join(root, ".fountain-managed-skills")) == manifest
      assert File.read!(Path.join(root, "current/SKILL.md")) == "Current skill"
      assert File.read!(Path.join(root, "personal/SKILL.md")) == "Keep my work"
      refute File.exists?(Path.join(root, "legacy"))
    end

    test "refuses malformed, unsafe and non-file manifests without touching skills", %{root: root} do
      manifest = Path.join(root, ".fountain-managed-skills")
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]

      for contents <- [
            "",
            "..\n../outside\n",
            "[]",
            ~s({"owned":["../outside"]}),
            ~s({"owned":["legacy",null]}),
            ~s({"owned":"legacy"})
          ] do
        File.write!(manifest, contents)
        assert {:ok, :invalid} = SandboxSkills.manifest_status(@handle, DiskRuntime)

        assert {:error, :invalid_skill_manifest} =
                 SandboxSkills.upgrade_manifest(@handle, DiskRuntime, previous)

        assert {:error, :invalid_skill_manifest} =
                 SandboxSkills.reconcile(@handle, DiskRuntime, [], previous)

        assert File.read!(manifest) == contents
        assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Old skill"
      end

      File.rm!(manifest)
      File.ln_s!(Path.join(root, "legacy/SKILL.md"), manifest)
      assert {:ok, :invalid} = SandboxSkills.manifest_status(@handle, DiskRuntime)

      assert {:error, :invalid_skill_manifest} =
               SandboxSkills.upgrade_manifest(@handle, DiskRuntime, previous)

      File.rm!(manifest)
      File.mkdir!(manifest)
      assert {:ok, :invalid} = SandboxSkills.manifest_status(@handle, DiskRuntime)
    end

    test "migration records ownership without changing skills and never reclaims released names",
         %{root: root} do
      manifest = Path.join(root, ".fountain-managed-skills")
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]

      assert {:ok, :missing} = SandboxSkills.manifest_status(@handle, DiskRuntime)
      refute File.exists?(manifest)
      assert :ok = SandboxSkills.upgrade_manifest(@handle, DiskRuntime, previous)
      assert {:ok, :present} = SandboxSkills.manifest_status(@handle, DiskRuntime)
      assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Old skill"
      refute File.exists?(Path.join(root, "fountain"))
      before = File.read!(manifest)
      assert :ok = SandboxSkills.upgrade_manifest(@handle, DiskRuntime, [])
      assert File.read!(manifest) == before

      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [], previous)
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Personal replacement")
      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [], previous)
      assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Personal replacement"
    end

    test "upgrades a fresh root and leaves unknown legacy ownership unrecorded", %{root: root} do
      missing_root = Path.join(root, "not-created-yet")
      Process.put(:skills_test_root, missing_root)

      assert {:error, :legacy_skill_ownership_unknown} =
               SandboxSkills.upgrade_manifest(@handle, DiskRuntime, nil)

      refute File.exists?(missing_root)
      assert :ok = SandboxSkills.upgrade_manifest(@handle, DiskRuntime, [])
      assert {:ok, :present} = SandboxSkills.manifest_status(@handle, DiskRuntime)
      assert :ok = SandboxSkills.upgrade_manifest(@handle, DiskRuntime, nil)
    end

    test "a failed ownership write leaves old skills intact and migration is retryable", %{
      root: root
    } do
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]
      expect(Managoat.Sandbox, :write_file, fn _, _, _ -> {:error, :offline} end)
      assert {:error, :offline} = SandboxSkills.reconcile(@handle, DiskRuntime, [], previous)
      assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Old skill"
      assert {:ok, :missing} = SandboxSkills.manifest_status(@handle, DiskRuntime)
      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [], previous)
      assert {:ok, :present} = SandboxSkills.manifest_status(@handle, DiskRuntime)
      refute File.exists?(Path.join(root, "legacy"))
    end

    test "missing source-lock evidence does not certify an unnamed legacy install", %{root: root} do
      File.mkdir_p!(Path.join(root, "unknown-remote"))

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        if Enum.any?(args, &String.contains?(&1, "skills_lock=")) do
          {:ok, "", 0}
        else
          {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
          {:ok, output, code}
        end
      end)

      for _retry <- 1..2 do
        assert {:error, :legacy_skill_ownership_unknown} =
                 SandboxSkills.upgrade_manifest(@handle, DiskRuntime, [
                   %{"source" => "owner/repo"}
                 ])

        assert {:ok, :missing} = SandboxSkills.manifest_status(@handle, DiskRuntime)
        assert File.dir?(Path.join(root, "unknown-remote"))
      end
    end

    test "current manifests do not consult an unavailable historical GitHub source lock", %{
      root: root
    } do
      File.write!(Path.join(root, ".fountain-managed-skills"), "{}")

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        refute Enum.any?(args, &String.contains?(&1, "skills_lock="))
        {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
        {:ok, output, code}
      end)

      assert :ok =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], [%{"source" => "owner/repo"}])
    end

    test "recovers unnamed legacy GitHub skills from the source lock", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy-remote"))
      File.write!(Path.join(root, "legacy-remote/SKILL.md"), "Old remote skill")
      File.mkdir_p!(Path.join(root, "unrelated"))

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        if Enum.any?(args, &String.contains?(&1, "skills_lock=")) do
          {:ok,
           Jason.encode!(%{
             "skills" => %{
               "legacy-remote" => %{"source" => "owner/repo", "sourceType" => "github"},
               "unrelated" => %{"source" => "another/repo", "sourceType" => "github"},
               "../outside" => %{"source" => "owner/repo", "sourceType" => "github"}
             }
           }), 0}
        else
          {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
          {:ok, output, code}
        end
      end)

      assert :ok =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], [%{"source" => "owner/repo"}])

      refute File.exists?(Path.join(root, "legacy-remote"))
      # Installed from a source this conversation never named.
      assert File.dir?(Path.join(root, "unrelated"))
    end

    test "a retained remote skill survives an offline reinstall", %{root: root} do
      skill = %{"source" => "owner/repo", "name" => "remote"}
      File.mkdir_p!(Path.join(root, "remote"))
      File.write!(Path.join(root, "remote/SKILL.md"), "Already installed")

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        case args do
          ["-lc", "npx " <> _] ->
            {:ok, "offline", 1}

          _ ->
            {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
            {:ok, output, code}
        end
      end)

      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [skill], [skill])
      assert File.read!(Path.join(root, "remote/SKILL.md")) == "Already installed"
    end

    test "tracks discovered GitHub skill names for a later removal", %{root: root} do
      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        case args do
          ["-lc", "npx " <> _] ->
            File.mkdir_p!(Path.join(root, "discovered"))
            File.write!(Path.join(root, "discovered/SKILL.md"), "Remote skill")
            {:ok, "", 0}

          _ ->
            {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
            {:ok, output, code}
        end
      end)

      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, [%{"source" => "owner/repo"}])
      assert File.read!(Path.join(root, ".fountain-managed-skills")) =~ "discovered"

      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, [])
      refute File.exists?(Path.join(root, "discovered"))
    end
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end
end
