defmodule Managoat.Runtimes.ACPCachedCheckTest do
  use ExUnit.Case, async: true
  use Mimic
  alias Managoat.Runtimes.ACP
  alias Managoat.Sandbox

  @handle %Sandbox.Handle{provider: :sprites, name: "cached-check"}

  test "a cached pin needs one exec and sends no bundle" do
    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:fountain, :adapter_install, :stop],
      fn _, _, metadata, pid ->
        if self() == pid, do: send(pid, {:install_stop, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    reject(&Sandbox.write_file/3)

    expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
      assert opts[:env] == [{"X", "1"}]
      assert opts[:timeout] == 30_000
      refute script =~ "npm install"
      {:ok, "__MANAGOAT_INSTALL__ cache_hit 1\n", 0}
    end)

    assert :ok = ACP.ensure_installed(@handle, "claude", [{"X", "1"}])
    assert_receive {:install_stop, %{"install_cache_hit" => 1, outcome: :ok}}
  end

  test "a miss uploads the verified bundle for the locked installer" do
    expect(Sandbox, :exec, fn @handle, _, _, _ -> {:ok, "", 75} end)

    expect(Managoat.Runtimes.BundleCache, :fetch, fn url, "sha512-" <> _, size ->
      assert url =~ "/acp-bundle-codex-2.2.2/codex-acp@2.2.2.linux-x64-glibc-image.tar.gz"
      assert is_integer(size) and size > 0
      {:ok, "verified bytes"}
    end)

    expect(Sandbox, :write_file, fn @handle,
                                    "/tmp/managoat-codex-acp@2.2.2.tar.gz",
                                    "verified bytes" ->
      :ok
    end)

    expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
      assert opts[:env] == [
               {"MANAGOAT_ACP_BUNDLE_FILE", "/tmp/managoat-codex-acp@2.2.2.tar.gz"},
               {"X", "1"}
             ]

      assert opts[:timeout] == 180_000
      assert script =~ "flock 9"
      for removed <- ["npm", "curl", "manifest"], do: refute(script =~ removed)
      {:ok, "__MANAGOAT_INSTALL__ cache_hit 0\n", 0}
    end)

    assert :ok = ACP.ensure_installed(@handle, "codex", [{"X", "1"}])
  end

  test "a miss whose bundle cannot be fetched fails without running the installer" do
    expect(Sandbox, :exec, fn @handle, _, _, _ -> {:ok, "", 75} end)

    expect(Managoat.Runtimes.BundleCache, :fetch, fn _url, _sri, _max ->
      {:error, {:bundle_http, 503}}
    end)

    reject(&Sandbox.spawn/4)

    assert {:error, {:acp_adapter_bundle, {:bundle_http, 503}}} =
             ACP.ensure_installed(@handle, "claude", [])
  end

  test "a failed install is the install's error, with its output" do
    expect(Sandbox, :exec, fn @handle, _, _, _ -> {:ok, "", 75} end)
    expect(Managoat.Runtimes.BundleCache, :fetch, fn _url, _sri, _max -> {:ok, "bytes"} end)

    expect(Sandbox, :write_file, fn @handle, _, "bytes" -> :ok end)

    expect(Sandbox, :exec, fn @handle, "bash", _args, _opts ->
      {:ok,
       "adapter install failed: step=verify: the adapter bundle does not match its pinned SHA-512\n",
       1}
    end)

    assert {:error, {:acp_adapter_install_exit, 1, out}} =
             ACP.ensure_installed(@handle, "claude", [])

    assert out =~ "does not match its pinned SHA-512"
  end

  test "a failed check does not masquerade as a miss or launch an install" do
    reject(&Sandbox.write_file/3)
    expect(Sandbox, :exec, fn _, _, _, _ -> {:error, :unavailable} end)

    assert {:error, {:acp_adapter_install, :unavailable}} =
             ACP.ensure_installed(@handle, "claude", [])
  end

  for {runtime, package, version, marker} <- [
        {"claude", "claude-agent-acp", "0.81.2", ".claude-executable"},
        {"codex", "codex-acp", "2.2.2", ".codex-executable"}
      ] do
    test "#{runtime} shell check refuses stale pins, broken launchers/links and missing image binaries" do
      runtime = unquote(runtime)
      home = Fountain.TmpDir.mkdir!("cached-pin")
      dir = Path.join(home, ".local/share/managoat/acp/#{unquote(package)}@#{unquote(version)}")
      link = Path.join(home, ".local/bin/#{unquote(package)}")
      target = Path.join(dir, "launch")
      File.mkdir_p!(dir)
      File.mkdir_p!(Path.dirname(link))
      File.write!(Path.join(dir, ".installed"), unquote(version))
      File.write!(target, "#!/bin/sh\n")
      File.chmod!(target, 0o700)
      File.ln_s!(target, link)
      parent = self()

      stub(Sandbox, :exec, fn _, "bash", ["-lc", script], _ ->
        send(parent, {:script, String.replace(script, "/home/sprite", home)})
        {:ok, "", 0}
      end)

      assert :ok = ACP.ensure_installed(@handle, runtime, [])
      assert_receive {:script, script}
      run = fn -> System.cmd("bash", ["--noprofile", "--norc", "-c", script]) end
      assert {"__MANAGOAT_INSTALL__ cache_hit 1\n", 0} = run.()
      File.write!(Path.join(dir, ".installed"), "stale")
      assert {_, 75} = run.()
      File.write!(Path.join(dir, ".installed"), unquote(version))
      File.write!(Path.join(dir, unquote(marker)), Path.join(home, "absent-image"))
      assert {_, 75} = run.()
      File.rm!(Path.join(dir, unquote(marker)))
      File.chmod!(target, 0o600)
      assert {_, 75} = run.()
      File.chmod!(target, 0o700)
      File.rm!(link)
      assert {_, 75} = run.()
      File.ln_s!("/wrong-pin/launch", link)
      assert {_, 75} = run.()
    end
  end
end
