defmodule Fountain.SandboxFiles.SnapshotsTest do
  @moduledoc """
  A parked sandbox's files, answered from the snapshot its park took
  (ADR 0063).

  The capture runs its two scripts through a real bash against a real
  repository: `Managoat.Sandbox.exec/4` is stubbed to run the command here,
  with `/home/sprite` mapped onto a scratch directory by `host_path/2`, the
  way the runner provider maps it. A mocked exec would prove the parsing and
  nothing about the scripts, and the scripts are where the bounds and the
  confinement live.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Crypto
  alias Fountain.Environments
  alias Fountain.SandboxFiles
  alias Fountain.SandboxFiles.Snapshot
  alias Fountain.SandboxFiles.Snapshots
  alias Fountain.TmpDir

  @home "/home/sprite"
  @track @home <> "/work/track"
  @secret "sk-env-secret-value"

  defp git_env, do: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, env: git_env(), stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  # A home with one repository in it, holding a committed file edited since,
  # a new file, an ignored dependency tree, a file past the per-file cap, a
  # secret, and a symlink out of the repository; and, beside the repository,
  # the kind of credential an agent's home keeps, which must never be taken.
  defp home! do
    home = TmpDir.mkdir!("sandbox-snapshot-home")
    repo = Path.join(home, "work/track")
    File.mkdir_p!(Path.join(repo, "sub"))
    git!(repo, ["init", "-q"])
    git!(repo, ["checkout", "-q", "-b", "main"])
    File.write!(Path.join(repo, "a.txt"), "one\n")
    File.write!(Path.join(repo, "sub/deep.txt"), "deep\n")
    File.write!(Path.join(repo, ".gitignore"), "node_modules/\n")
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "init"])

    File.write!(Path.join(repo, "a.txt"), "two\n")
    File.write!(Path.join(repo, "new.txt"), "fresh\n")
    File.write!(Path.join(repo, "secret.txt"), "token=" <> @secret <> "\n")
    File.write!(Path.join(repo, "big.bin"), :binary.copy("x", Snapshots.max_file_bytes() + 1))
    File.mkdir_p!(Path.join(repo, "node_modules/dep"))
    File.write!(Path.join(repo, "node_modules/dep/index.js"), "module.exports = 1\n")

    File.mkdir_p!(Path.join(home, ".codex"))
    File.write!(Path.join(home, ".codex/auth.json"), ~s({"token":"never-taken"}))
    File.ln_s!(Path.join(home, ".codex/auth.json"), Path.join(repo, "link.txt"))
    home
  end

  # `/home/sprite` onto the scratch home, as the runner maps it, and every
  # exec run here by a real bash.
  defp machine!(home) do
    stub(Managoat.Sandbox, :host_path, fn _handle, path ->
      String.replace_prefix(path, @home, home)
    end)

    stub(Managoat.Sandbox, :exec, fn _handle, command, args, _opts ->
      [flag, script | rest] = args

      {output, code} =
        System.cmd(command, [flag, "exec 2>/dev/null\n" <> script | rest], env: git_env())

      {:ok, output, code}
    end)
  end

  setup do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    env = insert_env(user_id: user.id)
    {:ok, _} = Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => @secret}, dek)
    agent = insert_agent(user_id: user.id, runtime: "claude")

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    home = home!()
    machine!(home)

    {:ok, user: user, sandbox: sandbox, home: home}
  end

  defp park!(sandbox) do
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [status: "suspended"])
    Repo.reload!(sandbox)
  end

  defp captured!(ctx) do
    assert {:ok, %Snapshot{}} = Snapshots.capture(ctx.sandbox, enabled: true)
    park!(ctx.sandbox)
  end

  defp parked_read(sandbox, path, opts \\ []), do: SandboxFiles.read(sandbox, path, opts)

  describe "a parked sandbox answers from its snapshot" do
    setup ctx, do: {:ok, parked: captured!(ctx)}

    test "files the agent changed, made or kept, with when they were taken", ctx do
      assert {:ok, %{content: "two\n", snapshot_at: %DateTime{} = at}} =
               parked_read(ctx.parked, @track <> "/a.txt")

      assert DateTime.diff(DateTime.utc_now(), at) < 60
      assert {:ok, %{content: "fresh\n", size: 6}} = parked_read(ctx.parked, @track <> "/new.txt")
      assert {:ok, %{content: "deep\n"}} = parked_read(ctx.parked, @track <> "/sub/deep.txt")

      # Relative to the working directory, as a live read resolves it.
      assert {:ok, %{content: "two\n"}} = parked_read(ctx.parked, "work/track/a.txt")
    end

    test "a secret is redacted, and was redacted before it was stored", ctx do
      assert {:ok, %{content: content}} = parked_read(ctx.parked, @track <> "/secret.txt")
      assert content =~ "[REDACTED]"
      refute content =~ @secret

      manifest = Snapshots.parked(ctx.parked)
      assert {:ok, stored} = Snapshots.content(manifest, @track <> "/secret.txt")
      refute stored =~ @secret

      row = Repo.get_by!(Snapshot, sandbox_id: ctx.sandbox.id)
      refute row.contents_ciphertext =~ "fresh"
      refute row.manifest_ciphertext =~ "work/track"
    end

    test "the listings down to the repository and inside it", ctx do
      assert {:ok, %{path: @home, entries: home, snapshot_at: %DateTime{}}} =
               SandboxFiles.list(ctx.parked, nil)

      assert %{type: "directory"} = Enum.find(home, &(&1.name == "work"))

      assert {:ok, %{entries: entries, truncated: false}} = SandboxFiles.list(ctx.parked, @track)
      by_name = Map.new(entries, &{&1.name, &1})

      assert %{type: "file", size: 4} = by_name["a.txt"]
      assert %{type: "directory"} = by_name["node_modules"]
      assert %{type: "symlink"} = by_name["link.txt"]
      assert %{type: "file"} = by_name["big.bin"]
      # Directories first, then by name, as the live listing orders them.
      assert hd(entries).type == "directory"
    end

    test "what the snapshot did not take reads as it always did: not ready", ctx do
      not_ready = {:error, {:sandbox_not_ready, "suspended"}}

      # Ignored, past the cap, a symlink, and a home directory outside every repository.
      assert parked_read(ctx.parked, @track <> "/node_modules/dep/index.js") == not_ready
      assert parked_read(ctx.parked, @track <> "/big.bin") == not_ready
      assert parked_read(ctx.parked, @track <> "/link.txt") == not_ready
      assert parked_read(ctx.parked, @home <> "/.codex/auth.json") == not_ready
      assert SandboxFiles.list(ctx.parked, @home <> "/.codex") == not_ready
      assert SandboxFiles.list(ctx.parked, @track <> "/node_modules") == not_ready

      manifest = Snapshots.parked(ctx.parked)
      assert Snapshots.content(manifest, @home <> "/.codex/auth.json") == :error
    end

    test "what the snapshot can rule out, and the confinement, answer as a live read would",
         ctx do
      assert {:error, :path_not_found} = parked_read(ctx.parked, @track <> "/missing.txt")
      assert {:error, :is_a_directory} = parked_read(ctx.parked, @track <> "/sub")
      assert {:error, :not_a_directory} = SandboxFiles.list(ctx.parked, @track <> "/a.txt")
      assert {:error, :path_outside_sandbox} = parked_read(ctx.parked, "/etc/passwd")
    end

    test "the default diff of the repository holding a listed directory", ctx do
      assert {:ok, %{diff: diff, repo_root: @track, truncated: false, snapshot_at: %DateTime{}}} =
               SandboxFiles.diff(ctx.parked, @track)

      assert diff =~ "-one\n+two"
      assert {:ok, %{diff: ^diff, path: path}} = SandboxFiles.diff(ctx.parked, @track <> "/sub")
      assert path == @track <> "/sub"

      assert {:ok, %{diff: short, truncated: true}} =
               SandboxFiles.diff(ctx.parked, @track, max_bytes: 10)

      assert byte_size(short) == 10

      not_ready = {:error, {:sandbox_not_ready, "suspended"}}
      assert SandboxFiles.diff(ctx.parked, @track, staged: true) == not_ready
      assert SandboxFiles.diff(ctx.parked, @track, ref: "HEAD") == not_ready
      # The home is listed, but it is not in a repository the snapshot knows.
      assert SandboxFiles.diff(ctx.parked, @home) == not_ready
    end

    test "git status in each of its three untracked modes", ctx do
      assert {:ok, %{branch: "main", entries: all, snapshot_at: %DateTime{}}} =
               SandboxFiles.status(ctx.parked, @track, untracked: "all")

      states = Map.new(all, &{&1.path, {&1.index, &1.worktree}})
      assert states["a.txt"] == {"unchanged", "modified"}
      assert states["new.txt"] == {"untracked", "untracked"}

      assert {:ok, %{entries: tracked}} = SandboxFiles.status(ctx.parked, @track, untracked: "no")
      assert Enum.map(tracked, & &1.path) == ["a.txt"]

      assert {:ok, %{entries: normal, untracked: "normal"}} =
               SandboxFiles.status(ctx.parked, @track)

      assert "new.txt" in Enum.map(normal, & &1.path)
    end
  end

  describe "when the snapshot is not read" do
    test "a ready sandbox reads live even with a snapshot on file", ctx do
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)
      File.write!(Path.join(ctx.home, "work/track/a.txt"), "three\n")

      assert {:ok, %{content: "three\n"} = live} = parked_read(ctx.sandbox, @track <> "/a.txt")
      refute Map.has_key?(live, :snapshot_at)
    end

    test "a parked sandbox whose park took no snapshot is not ready", ctx do
      assert parked_read(park!(ctx.sandbox), @track <> "/a.txt") ==
               {:error, {:sandbox_not_ready, "suspended"}}
    end

    test "another tenant's sandbox never reads this one's snapshot", ctx do
      parked = captured!(ctx)
      stranger = insert_verified_user()
      assert Snapshots.parked(%{parked | user_id: stranger.id}) == nil
    end
  end

  describe "capture" do
    test "is off unless configured, and a park without one takes none", ctx do
      assert Snapshots.capture(ctx.sandbox) == :skipped
      refute Repo.get_by(Snapshot, sandbox_id: ctx.sandbox.id)
    end

    test "replaces the last snapshot, so a parked read sees the latest park", ctx do
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)
      File.write!(Path.join(ctx.home, "work/track/a.txt"), "three\n")
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)

      assert Repo.aggregate(from(s in Snapshot, where: s.sandbox_id == ^ctx.sandbox.id), :count) ==
               1

      assert {:ok, %{content: "three\n"}} = parked_read(park!(ctx.sandbox), @track <> "/a.txt")
    end

    test "a capture that fails removes the previous one rather than leave it standing", ctx do
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)
      stub(Managoat.Sandbox, :exec, fn _handle, _command, _args, _opts -> {:error, :closed} end)

      log =
        capture_log(fn ->
          assert {:error, {:exec, :closed}} = Snapshots.capture(ctx.sandbox, enabled: true)
        end)

      assert log =~ "sandbox snapshot failed for #{ctx.sandbox.id}"
      refute Repo.get_by(Snapshot, sandbox_id: ctx.sandbox.id)
    end

    test "a capture that raises answers an error and removes the previous one", ctx do
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)

      stub(Managoat.Sandbox, :exec, fn _handle, _command, _args, _opts ->
        raise "adapter exploded"
      end)

      log =
        capture_log(fn ->
          assert {:error, :capture_raised} = Snapshots.capture(ctx.sandbox, enabled: true)
        end)

      assert log =~ "adapter exploded"
      refute Repo.get_by(Snapshot, sandbox_id: ctx.sandbox.id)
    end

    test "stops taking repositories once the survey's total is spent, each one whole", ctx do
      other = Path.join(ctx.home, "work/other")
      File.mkdir_p!(other)
      git!(other, ["init", "-q"])
      File.write!(Path.join(other, "b.txt"), "bee\n")

      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true, max_survey_bytes: 1)
      assert [repo] = Snapshots.parked(park!(ctx.sandbox)).repos
      assert repo.root in [@track, @home <> "/work/other"]
      assert repo.status_all != ""

      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id), set: [status: "ready"])
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)
      assert length(Snapshots.parked(park!(ctx.sandbox)).repos) == 2
    end

    test "each capture is a span with its outcome, for what it costs a park", ctx do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "snapshot-span-#{inspect(ref)}",
        [:fountain, :sandbox_snapshot, :stop],
        fn _event, %{duration: duration}, meta, _ ->
          send(test_pid, {ref, duration, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("snapshot-span-#{inspect(ref)}") end)

      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)
      sandbox_id = ctx.sandbox.id
      assert_receive {^ref, duration, %{outcome: :ok, sandbox_id: ^sandbox_id}}
      assert is_integer(duration)

      stub(Managoat.Sandbox, :exec, fn _handle, _command, _args, _opts -> {:error, :closed} end)
      capture_log(fn -> Snapshots.capture(ctx.sandbox, enabled: true) end)
      assert_receive {^ref, _duration, %{outcome: :error, sandbox_id: ^sandbox_id}}
    end

    test "a machine that stops for good drops its snapshot", ctx do
      assert {:ok, _} = Snapshots.capture(ctx.sandbox, enabled: true)
      terminated = %{ctx.sandbox | status: "terminated"}

      assert :ok = Conversations.sandbox_status_effects(terminated, "suspended")
      refute Repo.get_by(Snapshot, sandbox_id: ctx.sandbox.id)
    end
  end

  describe "plan/2" do
    test "lists the way down and keeps changed files first, only in listed directories" do
      repo = %{
        root: "/home/sprite/work/r",
        files: [
          "/home/sprite/work/r/z.txt",
          "/home/sprite/work/r/a/b/deep.txt",
          "/home/sprite/work/r/m.txt"
        ],
        changed: ["/home/sprite/work/r/a/b/deep.txt"]
      }

      {dirs, files} = Snapshots.plan("/home/sprite", [repo])

      assert dirs == [
               "/home/sprite",
               "/home/sprite/work",
               "/home/sprite/work/r",
               "/home/sprite/work/r/a",
               "/home/sprite/work/r/a/b"
             ]

      assert files == [
               "/home/sprite/work/r/a/b/deep.txt",
               "/home/sprite/work/r/m.txt",
               "/home/sprite/work/r/z.txt"
             ]
    end
  end
end
