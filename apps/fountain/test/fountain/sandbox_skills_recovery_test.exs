defmodule Fountain.SandboxSkillsRecoveryTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.SandboxSkills

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "skills-recovery"}
  @remote [%{"source" => "owner/repo"}]

  defmodule DiskRuntime do
    def skills_root, do: Process.get(:skills_recovery_root)
    def skills_sh_agent, do: "claude"
  end

  setup :verify_on_exit!

  setup do
    root = Fountain.TmpDir.mkdir!("skills-recovery")
    Process.put(:skills_recovery_root, root)

    stub(Managoat.Sandbox, :write_file, fn _, path, content -> write_file(path, content) end)
    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ -> exec(root, args) end)

    %{root: root, manifest: Path.join(root, ".fountain-managed-skills")}
  end

  test "a failed ownership commit leaves the install pending across wake retries", ctx do
    stub(Managoat.Sandbox, :write_file, fn _, path, content ->
      if path == ctx.manifest and String.contains?(content, "discovered") and
           not Process.get(:failed_commit, false) do
        Process.put(:failed_commit, true)
        {:error, :offline}
      else
        write_file(path, content)
      end
    end)

    assert {:error, :offline} = SandboxSkills.mount(@handle, DiskRuntime, @remote)
    assert File.exists?(Path.join(ctx.root, "discovered/SKILL.md"))
    assert pending?(ctx)
    pending = File.read!(ctx.manifest)

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.reconcile(@handle, DiskRuntime, @remote, @remote)

    assert File.read!(ctx.manifest) == pending
    assert File.exists?(Path.join(ctx.root, "discovered/SKILL.md"))
  end

  test "an install cannot start until its intent is durable", ctx do
    stub(Managoat.Sandbox, :write_file, fn _, path, content ->
      if path == ctx.manifest and Map.has_key?(Jason.decode!(content), "installing"),
        do: {:error, :offline},
        else: write_file(path, content)
    end)

    assert {:error, :offline} = SandboxSkills.mount(@handle, DiskRuntime, @remote)
    refute_received :installed_remote
    refute File.exists?(Path.join(ctx.root, "discovered"))
    refute pending?(ctx)
  end

  test "a wake leaves an interrupted install pending and its output in place", ctx do
    interrupt_install(ctx)
    pending = File.read!(ctx.manifest)
    assert_received :installed_remote

    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
      if Enum.any?(args, &String.contains?(&1, "skills_lock=")),
        do: {:ok, "", 0},
        else: exec(ctx.root, args)
    end)

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)

    assert File.read!(ctx.manifest) == pending
    assert File.exists?(Path.join(ctx.root, "discovered/SKILL.md"))
    refute_received :installed_remote
  end

  test "stale source lock cannot adopt a personal replacement after interruption", ctx do
    assert :ok = SandboxSkills.mount(@handle, DiskRuntime, @remote)
    assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)
    refute File.exists?(Path.join(ctx.root, "discovered"))

    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
      if match?(["-lc", "npx " <> _], args), do: raise("interrupted before execution")
      exec(ctx.root, args)
    end)

    assert_raise RuntimeError, "interrupted before execution", fn ->
      SandboxSkills.mount(@handle, DiskRuntime, @remote)
    end

    pending = File.read!(ctx.manifest)
    write_file(Path.join(ctx.root, "discovered/SKILL.md"), "Personal replacement")

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)

    assert File.read!(ctx.manifest) == pending
    assert File.read!(Path.join(ctx.root, "discovered/SKILL.md")) == "Personal replacement"
  end

  test "an overlapping reconcile cannot consume an active install", ctx do
    owner = self()

    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
      if match?(["-lc", "npx " <> _], args) do
        send(owner, {:installer_started, self()})

        receive do
          :finish_install -> exec(ctx.root, args)
        after
          5_000 -> flunk("installer was not released")
        end
      else
        exec(ctx.root, args)
      end
    end)

    installer =
      Task.async(fn ->
        Mimic.allow(Managoat.Sandbox, owner, self())
        Process.put(:skills_recovery_root, ctx.root)
        SandboxSkills.mount(@handle, DiskRuntime, @remote)
      end)

    assert_receive {:installer_started, pid}, 2_000
    pending = File.read!(ctx.manifest)

    assert {:error, :skill_reconciliation_busy} =
             SandboxSkills.reconcile(@handle, DiskRuntime, @remote, [])

    assert File.read!(ctx.manifest) == pending
    send(pid, :finish_install)
    assert :ok = Task.await(installer)
    assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)
    refute File.exists?(Path.join(ctx.root, "discovered"))
  end

  test "unreadable pre-install provenance cannot be treated as an empty lock", ctx do
    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
      if Enum.any?(args, &String.contains?(&1, "skills_lock=")),
        do: {:ok, "{partial", 0},
        else: exec(ctx.root, args)
    end)

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.mount(@handle, DiskRuntime, @remote)

    refute_received :installed_remote
    refute File.exists?(Path.join(ctx.root, "discovered"))
  end

  test "automatic retry leaves pre-execution intent intact even after its caller exits", ctx do
    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
      if match?(["-lc", "npx " <> _], args), do: raise("caller died")
      exec(ctx.root, args)
    end)

    assert_raise RuntimeError, "caller died", fn ->
      SandboxSkills.mount(@handle, DiskRuntime, @remote)
    end

    pending = File.read!(ctx.manifest)

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)

    assert File.read!(ctx.manifest) == pending
    # Remote work can appear after the caller and its application lock are gone.
    write_file(Path.join(ctx.root, "discovered/SKILL.md"), "Late installer output")

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)

    assert File.read!(ctx.manifest) == pending
    assert File.read!(Path.join(ctx.root, "discovered/SKILL.md")) == "Late installer output"
  end

  test "unsafe or incomplete pending records fail closed", ctx do
    write_file(Path.join(ctx.root, "personal/SKILL.md"), "Preserve me")

    valid = %{
      "version" => 1,
      "managed" => %{},
      "installing" => %{
        "source" => "owner/repo",
        "name" => nil,
        "before" => [],
        "locked_before" => []
      }
    }

    for invalid <- [
          put_in(valid, ["managed"], %{"bad" => ["../outside"]}),
          put_in(valid, ["installing", "before"], ["../outside"]),
          put_in(valid, ["installing", "name"], "../outside"),
          put_in(valid, ["installing", "source"], nil),
          Map.put(valid, "installing", %{}),
          Map.put(valid, "version", 2)
        ] do
      original = Jason.encode!(invalid)
      File.write!(ctx.manifest, original)

      assert {:error, :invalid_skill_manifest} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)

      assert File.read!(ctx.manifest) == original
      assert File.read!(Path.join(ctx.root, "personal/SKILL.md")) == "Preserve me"
      refute_received :installed_remote
    end
  end

  test "known inline destinations remain owned after a final commit failure", ctx do
    selection = [%{"name" => "inline", "content" => "Inline skill"}]

    stub(Managoat.Sandbox, :write_file, fn _, path, content ->
      if path == ctx.manifest and File.exists?(Path.join(ctx.root, "inline/SKILL.md")) and
           not Process.get(:failed_inline_commit, false) do
        Process.put(:failed_inline_commit, true)
        {:error, :offline}
      else
        write_file(path, content)
      end
    end)

    assert {:error, :offline} = SandboxSkills.mount(@handle, DiskRuntime, selection)
    assert File.read!(Path.join(ctx.root, "inline/SKILL.md")) == "Inline skill"
    assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [], nil)
    refute File.exists?(Path.join(ctx.root, "inline"))
  end

  defp interrupt_install(ctx) do
    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
      case args do
        ["-lc", "npx " <> _] ->
          result = exec(ctx.root, args)
          Process.put(:interrupt_observation, true)
          result

        _ ->
          if Process.delete(:interrupt_observation),
            do: {:error, :offline},
            else: exec(ctx.root, args)
      end
    end)

    assert {:error, :offline} = SandboxSkills.mount(@handle, DiskRuntime, @remote)
    assert pending?(ctx)
    stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ -> exec(ctx.root, args) end)
  end

  defp pending?(ctx),
    do: ctx.manifest |> File.read!() |> Jason.decode!() |> Map.has_key?("installing")

  defp exec(root, ["-lc", "npx " <> _]) do
    write_file(Path.join(root, "discovered/SKILL.md"), "Remote skill")
    Process.put(:remote_installed, true)
    send(self(), :installed_remote)
    {:ok, "", 0}
  end

  defp exec(_root, args) do
    if Enum.any?(args, &String.contains?(&1, "skills_lock=")) do
      if Process.get(:remote_installed, false) do
        {:ok,
         Jason.encode!(%{
           "skills" => %{
             "discovered" => %{"source" => "owner/repo", "sourceType" => "github"}
           }
         }), 0}
      else
        {:ok, "", 0}
      end
    else
      {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
      {:ok, output, code}
    end
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, content)
  end
end
