defmodule Fountain.Machines.ParkSnapshotTest do
  @moduledoc """
  The park takes the files API's snapshot (ADR 0063): inside its transition,
  before the suspend, and without ever letting a failed one stop the park.

  `async: false` because snapshots are switched on for the module through
  the application environment, which every other suite reads as off.
  """
  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Park
  alias Fountain.SandboxFiles
  alias Fountain.SandboxFiles.Snapshot
  alias Fountain.SandboxFiles.Snapshots
  alias Fountain.TmpDir

  @home "/home/sprite"

  defp git_env, do: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, env: git_env(), stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
  end

  setup do
    previous = Application.get_env(:fountain, Snapshots)
    Application.put_env(:fountain, Snapshots, enabled: true)
    on_exit(fn -> Application.put_env(:fountain, Snapshots, previous) end)

    home = TmpDir.mkdir!("park-snapshot-home")
    repo = Path.join(home, "work/track")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    File.write!(Path.join(repo, "notes.md"), "what the agent wrote\n")

    stub(Managoat.Sandbox, :host_path, fn _handle, path ->
      String.replace_prefix(path, @home, home)
    end)

    stub(Managoat.Sandbox, :exec, fn _handle, command, [flag, script | rest], _opts ->
      {output, code} =
        System.cmd(command, [flag, "exec 2>/dev/null\n" <> script | rest], env: git_env())

      {:ok, output, code}
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    {:ok, sandbox: sandbox, notes: @home <> "/work/track/notes.md"}
  end

  defp opts, do: [actor: "system:sandbox_reaper", reason: :idle]

  test "is taken inside the transition and before the suspend, and answers once parked", ctx do
    test = self()

    stub(Managoat.Sandbox, :supports?, fn _provider, cap -> cap == :suspend end)

    expect(Managoat.Sandbox, :suspend, fn _handle ->
      row = Repo.reload!(ctx.sandbox)
      send(test, {:at_suspend, row, Repo.get_by(Snapshot, sandbox_id: row.id)})
      :ok
    end)

    assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())

    assert_received {:at_suspend, %Sandbox{transition: "parking", status: "ready"}, %Snapshot{}},
                    "the snapshot was not on file before the machine was suspended"

    parked = Repo.reload!(ctx.sandbox)
    assert parked.status == "suspended"

    assert {:ok, %{content: "what the agent wrote\n", snapshot_at: %DateTime{}}} =
             SandboxFiles.read(parked, ctx.notes)
  end

  test "a capture that fails leaves the park to go ahead, and the sandbox reads as before", ctx do
    stub(Managoat.Sandbox, :supports?, fn _provider, cap -> cap == :suspend end)
    stub(Managoat.Sandbox, :exec, fn _handle, _command, _args, _opts -> {:error, :closed} end)
    expect(Managoat.Sandbox, :suspend, fn _handle -> :ok end)

    log = capture_log(fn -> assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts()) end)
    assert log =~ "sandbox snapshot failed"

    parked = Repo.reload!(ctx.sandbox)
    assert parked.status == "suspended"
    refute Repo.get_by(Snapshot, sandbox_id: parked.id)
    assert SandboxFiles.read(parked, ctx.notes) == {:error, {:sandbox_not_ready, "suspended"}}
  end
end
