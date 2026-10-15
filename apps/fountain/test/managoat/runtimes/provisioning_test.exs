defmodule Managoat.Runtimes.ProvisioningTest do
  @moduledoc """
  The imperative half of each runtime — `prepare_sandbox/3`, `write_config/2`
  and the adapter install — driven against a stubbed sandbox.

  In Fountain these paths were covered by the conversation server's
  provisioning tests, which drive them through the real server. A package
  cannot lean on its host's tests, so the shape of every exec and write is
  pinned here: the script each runtime runs, the file it writes, and the
  tagged error it answers with when the sandbox refuses.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.{ACP, Claude, Codex, Gemini}
  alias Managoat.Sandbox

  setup :verify_on_exit!

  @handle %Sandbox.Handle{provider: :sprites, name: "prov-test"}

  describe "Codex" do
    test "default_env/2 exports OPENAI_API_KEY, or nothing" do
      assert Codex.default_env(nil, %{openai_api_key: "sk"}) == [{"OPENAI_API_KEY", "sk"}]
      assert Codex.default_env(nil, %{openai_api_key: ""}) == []
      assert Codex.default_env(nil, %{}) == []
    end

    test "prepare_sandbox/3 writes auth.json as `codex login --with-api-key` does" do
      expect(Sandbox, :write_file, fn @handle, "/home/sprite/.codex/auth.json", body, opts ->
        assert opts[:mode] == 0o600
        assert Jason.decode!(body) == %{"auth_mode" => "apikey", "OPENAI_API_KEY" => "sk-1"}
        :ok
      end)

      # No CLI involved: a sandbox without `codex` on PATH (a self-hosted
      # runner) logs in the same way.
      reject(&Sandbox.spawn/4)

      assert :ok = Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk-1"}])
    end

    test "a refused write is a tagged error" do
      expect(Sandbox, :write_file, fn _h, _p, _b, _o -> {:error, {:unavailable, :closed}} end)

      assert {:error, {:codex_auth_write, {:unavailable, :closed}}} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk"}])
    end

    test "no key in the env is named, rather than left for the first turn to 401 on" do
      reject(&Sandbox.write_file/4)
      assert {:error, :missing_openai_api_key} = Codex.prepare_sandbox(@handle, nil, [])

      assert {:error, :missing_openai_api_key} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", ""}])
    end
  end

  describe "Claude" do
    test "has no sandbox bootstrap: the pinned CLI lists its models itself" do
      reject(&Sandbox.exec/4)

      refute Managoat.Runtimes.implements?(Claude, :prepare_sandbox, 3)

      assert :ok =
               Managoat.Runtimes.prepare_sandbox(Claude, @handle, nil, [
                 {"ANTHROPIC_API_KEY", "sk"}
               ])
    end

    test "model_env/2 dispatches to claude, and is empty for a runtime without it" do
      assert Managoat.Runtimes.model_env(Claude, "claude-opus-5") ==
               [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]

      assert Managoat.Runtimes.model_env(Codex, "gpt-5") == []
    end

    test "client_capabilities/2: claude declares form elicitation only under a policy that asks (#2492)" do
      default = Managoat.ACP.Protocol.default_client_capabilities()
      declared = Map.put(default, :elicitation, %{form: %{}})
      asks = %{"default" => "auto_allow", "execute" => "ask"}

      assert Managoat.Runtimes.client_capabilities(Claude, asks) == declared
      assert Managoat.Runtimes.client_capabilities(Claude, %{"default" => "ask"}) == declared

      # Asks nobody: the adapter keeps AskUserQuestion removed, and nothing waits.
      for policy <- [nil, %{}, %{"default" => "auto_allow"}, %{"execute" => "auto_deny"}] do
        assert Managoat.Runtimes.client_capabilities(Claude, policy) == default, inspect(policy)
      end

      assert Managoat.Runtimes.client_capabilities(Codex, asks) == default
      # A custom `acp` runtime has no module.
      assert Managoat.Runtimes.client_capabilities(nil, asks) == default
    end
  end

  describe "configuration no-ops" do
    test "an agent without runtime-specific config writes nothing" do
      reject(&Sandbox.write_file/3)

      assert :ok = Managoat.Runtimes.Instructions.write(@handle, "claude", %{})
    end
  end

  describe "Gemini" do
    test "default_env/2 exports the key and HOME=/tmp, and HOME alone without a key" do
      assert Gemini.default_env(nil, %{gemini_api_key: "g"}) ==
               [{"GEMINI_API_KEY", "g"}, {"HOME", "/tmp"}]

      assert Gemini.default_env(nil, %{gemini_api_key: ""}) == [{"HOME", "/tmp"}]
      assert Gemini.default_env(nil, %{}) == [{"HOME", "/tmp"}]
    end

    test "write_config/2 writes user-scope MCP servers under gemini's own HOME" do
      test = self()

      expect(Sandbox, :write_file, fn @handle, path, body ->
        send(test, {:wrote, path, body})
        :ok
      end)

      servers = %{"fs" => %{"command" => "mcp-fs"}}
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: servers})

      assert_receive {:wrote, "/tmp/.gemini/settings.json", body}
      assert Jason.decode!(body) == %{"mcpServers" => servers}
    end

    test "write_config/2 writes nothing without servers" do
      reject(&Sandbox.write_file/3)
      assert :ok = Gemini.write_config(@handle, nil)
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: %{}})
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: nil})
    end

    test "a refused config write is reported, not swallowed" do
      # `:not_found` is permanent in the sandbox taxonomy, so Retry does not
      # spend its attempts on it and the error comes straight back.
      expect(Sandbox, :write_file, fn _h, _p, _b -> {:error, :not_found} end)

      assert {:error, {:runtime_config, "/tmp/.gemini/settings.json", :not_found}} =
               Gemini.write_config(@handle, %{mcp_servers: %{"a" => %{}}})
    end

    test "prepare_sandbox/3 installs the session-store workaround, then git-inits the workspace" do
      test = self()

      expect(Sandbox, :write_file, fn @handle, path, _body ->
        send(test, {:wrote, path})
        :ok
      end)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts[:env]})
        {:ok, "", 0}
      end)

      env = [{"HOME", "/tmp"}]
      assert :ok = Gemini.prepare_sandbox(@handle, nil, env)

      assert_receive {:wrote, "/tmp/gemini-session-consolidate.js"}
      assert_receive {:exec, script, ^env}
      assert script =~ "/tmp/gemini-workspace/.git"
      assert script =~ "git init -q"
      # The CLI is installed, pinned, only where the image did not bring it.
      assert script =~ "if ! command -v gemini >/dev/null; then"
      assert script =~ "npm install -g --no-progress --silent @google/gemini-cli@0.59.0"
    end

    test "a failed workspace init is a tagged error" do
      stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "fatal", 128} end)

      assert {:error, {:gemini_workspace_init_exit, 128}} =
               Gemini.prepare_sandbox(@handle, nil, [])

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)

      assert {:error, {:gemini_workspace_init, :unavailable}} =
               Gemini.prepare_sandbox(@handle, nil, [])
    end
  end

  describe "ACP.install/3 for an adapter runtime" do
    @claude_dir "/home/sprite/.local/share/managoat/acp/claude-agent-acp@0.81.2"

    test "claude writes its manifest, then installs into a versioned directory" do
      test = self()

      expect(Sandbox, :write_file, fn @handle, path, body ->
        send(test, {:manifest, path, body})
        :ok
      end)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts})
        {:ok, "", 0}
      end)

      assert :ok = ACP.install(@handle, "claude", [{"X", "1"}])

      assert_receive {:manifest, path, body}
      assert path == @claude_dir <> ".tsv"
      assert body =~ "node_modules/@agentclientprotocol/claude-agent-acp\thttps://"

      assert_receive {:exec, script, opts}
      assert opts[:env] == [{"X", "1"}]
      assert script =~ "want=0.81.2"
      assert script =~ "dir=#{@claude_dir}"
      assert script =~ "link=/home/sprite/.local/bin/claude-agent-acp"
      assert script =~ "flock 9"
      assert script =~ "npm install --prefix \"$dir.tmp\""
      refute script =~ "npm install -g"
    end

    test "a manifest that cannot be written leaves the install to npm" do
      expect(Sandbox, :write_file, fn _h, _p, _b -> {:error, :unavailable} end)
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "", 0} end)

      assert :ok = ACP.install(@handle, "claude", [])
    end

    test "codex has no manifest and installs with npm the same way" do
      reject(&Sandbox.write_file/3)

      expect(Sandbox, :exec, fn _h, _c, ["-lc", script], _o ->
        assert script =~ "dir=/home/sprite/.local/share/managoat/acp/codex-acp@2.2.2"
        assert script =~ "link=/home/sprite/.local/bin/codex-acp"
        assert script =~ "@agentclientprotocol/codex-acp@2.2.2"
        {:ok, "", 0}
      end)

      assert :ok = ACP.install(@handle, "codex", [])
    end

    @tag :tmp_dir
    test "an installed pin is recognised without running anything", %{tmp_dir: home} do
      target = installed_fixture(home)
      File.ln_s!(target, Path.join(home, ".local/bin/claude-agent-acp"))

      assert {_out, 0, calls} = run_installer(home)
      assert calls == ""
    end

    @tag :tmp_dir
    test "a missing link is repointed without reinstalling", %{tmp_dir: home} do
      target = installed_fixture(home)

      assert {_out, 0, calls} = run_installer(home)
      assert calls == ""
      assert File.read_link!(Path.join(home, ".local/bin/claude-agent-acp")) == target
    end

    @tag :tmp_dir
    test "an install from before the launcher gains one without reinstalling", %{tmp_dir: home} do
      target = installed_fixture(home)
      File.rm!(target)
      File.rm!(Path.join(versioned_dir(home), ".node"))

      entry =
        Path.join(
          versioned_dir(home),
          "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
        )

      File.ln_s!(entry, Path.join(home, ".local/bin/claude-agent-acp"))

      assert {_out, 0, calls} = run_installer(home)
      assert calls == ""
      assert File.read_link!(Path.join(home, ".local/bin/claude-agent-acp")) == target
      assert File.read!(Path.join(versioned_dir(home), ".node")) == "/opt/node/bin/node\n"
      assert {_, 0} = System.cmd("test", ["-x", target])
    end

    @tag :tmp_dir
    test "the launcher runs the entry on the recorded node, not the one on PATH", %{tmp_dir: home} do
      launch = installed_fixture(home)
      recorded = fake_node(home, "recorded")
      File.write!(Path.join(versioned_dir(home), ".node"), recorded <> "\n")
      on_path = fake_node(Path.join(home, "path"), "shim")

      {out, 0} =
        System.cmd(launch, ["--flag", "two words"],
          env: [{"PATH", Path.dirname(on_path) <> ":/usr/bin:/bin"}]
        )

      entry =
        Path.join(
          versioned_dir(home),
          "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
        )

      assert out == "recorded|#{entry}|--flag|two words\n"
    end

    @tag :tmp_dir
    test "a recorded node that is gone or relative falls back to the one on PATH", %{
      tmp_dir: home
    } do
      launch = installed_fixture(home)
      on_path = fake_node(Path.join(home, "path"), "shim")
      env = [{"PATH", Path.dirname(on_path) <> ":/usr/bin:/bin"}]

      for recorded <- ["/no/such/node\n", "node\n", ""] do
        File.write!(Path.join(versioned_dir(home), ".node"), recorded)
        assert {"shim|" <> _, 0} = System.cmd(launch, [], env: env)
      end

      File.rm!(Path.join(versioned_dir(home), ".node"))
      assert {"shim|" <> _, 0} = System.cmd(launch, [], env: env)
    end

    @tag :tmp_dir
    test "the manifest installs the matching platform package, checked and unpacked", %{
      tmp_dir: home
    } do
      dir = versioned_dir(home)
      File.mkdir_p!(Path.dirname(dir))

      manifest = [
        tarball_row(home, "node_modules/@agentclientprotocol/claude-agent-acp", %{
          "dist/index.js" => "#!/usr/bin/env node\n"
        }),
        tarball_row(home, "node_modules/native-here", %{"claude" => "bin"},
          os: "linux",
          cpu: host_cpu(),
          libc: "glibc,musl"
        ),
        tarball_row(home, "node_modules/native-elsewhere", %{"claude" => "bin"},
          os: "darwin",
          cpu: "arm64"
        )
      ]

      File.write!(dir <> ".tsv", Enum.join(manifest, "\n") <> "\n")

      assert {_out, 0, calls} = run_installer(home)
      assert calls == ""
      assert File.read!(Path.join(dir, ".installed")) == "0.81.2"
      assert File.exists?(Path.join(dir, "node_modules/native-here/claude"))
      refute File.exists?(Path.join(dir, "node_modules/native-elsewhere"))
      refute File.exists?(Path.join(dir, ".dl"))
      refute File.exists?(Path.join(dir, ".timing"))

      timing = File.read!(Path.join(dir, ".install-timing"))
      assert timing =~ ~r/^method manifest$/m
      assert timing =~ ~r/^start \d+\.\d{3}$/m
      assert timing =~ ~r/^installed \d+\.\d{3}$/m
      # Milliseconds per package: a date format that ran seconds and
      # nanoseconds together once reported 19-digit "durations".
      for [ms] <- Regex.scan(~r/^package \S+ (\d+)$/m, timing, capture: :all_but_first),
          do: assert(String.to_integer(ms) < 60_000)

      assert timing =~ ~r/^package node_modules\/\S+ \d+$/m

      entry = Path.join(dir, "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")

      assert File.read_link!(Path.join(home, ".local/bin/claude-agent-acp")) ==
               Path.join(dir, "launch")

      assert File.read!(Path.join(dir, "launch")) =~ entry
      refute File.read!(Path.join(dir, "launch")) =~ ".tmp"
      assert File.read!(Path.join(dir, ".node")) == "/opt/node/bin/node\n"
      refute File.exists?(dir <> ".node")
      assert %{mode: mode} = File.stat!(entry)
      assert Bitwise.band(mode, 0o111) != 0
    end

    @tag :tmp_dir
    test "an integrity mismatch falls back to npm", %{tmp_dir: home} do
      dir = versioned_dir(home)
      File.mkdir_p!(Path.dirname(dir))

      row =
        tarball_row(home, "node_modules/@agentclientprotocol/claude-agent-acp", %{
          "dist/index.js" => "x"
        })

      [path, url, _sri | rest] = String.split(row, "\t")

      File.write!(
        dir <> ".tsv",
        Enum.join([path, url, "sha512-bm90IHRoaXM=" | rest], "\t") <> "\n"
      )

      assert {out, 0, calls} = run_installer(home)
      assert out =~ "integrity mismatch"
      assert out =~ "manifest install failed"
      assert calls =~ "npm install --prefix"
      assert File.read!(Path.join(dir, ".installed")) == "0.81.2"
      assert File.read!(Path.join(dir, ".install-timing")) =~ ~r/^method npm$/m
      assert File.read!(Path.join(dir, ".node")) == "/opt/node/bin/node\n"
    end

    @tag :tmp_dir
    test "without a manifest the pin installs with npm", %{tmp_dir: home} do
      assert {out, 0, calls} = run_installer(home)
      refute out =~ "manifest install failed"
      assert calls =~ "npm install --prefix"
      assert calls =~ "@agentclientprotocol/claude-agent-acp@0.81.2"
    end

    test "a failed install names the exit code and the first 500 bytes of output" do
      long = String.duplicate("e", 600)
      stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, long, 1} end)

      assert {:error, {:acp_adapter_install_exit, 1, out}} = ACP.install(@handle, "claude", [])
      assert byte_size(out) == 500

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)
      assert {:error, {:acp_adapter_install, :unavailable}} = ACP.install(@handle, "claude", [])
    end
  end

  # The claude installer, run for real under `bash -lc` with `/home/sprite`
  # moved to `home`. The home has a ~/.bash_logout that fails, as the sprite's
  # does outside a console: an `exit` at the installer's top level would turn
  # success into exit 1 (the bug a fast-path `exit 0` shipped with). npm is a
  # stub that records its call and lays out the package, so no package manager
  # runs. Answers {output, status, npm calls}.
  defp run_installer(home) do
    File.mkdir_p!(Path.join(home, ".local/bin"))
    File.write!(Path.join(home, ".bash_logout"), "false\n")
    calls = Path.join(home, "npm-calls")

    script = String.replace(claude_installer(), "/home/sprite", home)

    # `node -p process.execPath` answers as a sprite's would, from an nvm tree.
    npm = ~s"""
    node() { echo /opt/node/bin/node; }
    npm() {
      echo "npm $*" >>#{calls}
      local d=$3
      mkdir -p "$d/node_modules/@agentclientprotocol/claude-agent-acp/dist"
      : >"$d/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
    }
    """

    {out, status} =
      System.cmd("bash", ["-lc", npm <> script], env: [{"HOME", home}], stderr_to_stdout: true)

    {out, status, if(File.exists?(calls), do: File.read!(calls), else: "")}
  end

  # The script `ACP.install/3` runs for claude, as it hands it to the sandbox.
  defp claude_installer do
    stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)

    stub(Sandbox, :exec, fn _h, "bash", ["-lc", script], _o ->
      send(self(), {:installer, script})
      {:ok, "", 0}
    end)

    :ok = ACP.install(@handle, "claude", [])
    assert_received {:installer, script}
    script
  end

  defp versioned_dir(home),
    do: Path.join(home, ".local/share/managoat/acp/claude-agent-acp@0.81.2")

  # An installed pin as the installer leaves it, launcher included, but with
  # no PATH link and no record of the npm call it took; answers the launcher's
  # path, which is what the link points at.
  defp installed_fixture(home) do
    {_out, 0, _calls} = run_installer(home)
    File.rm!(Path.join(home, "npm-calls"))
    File.rm!(Path.join(home, ".local/bin/claude-agent-acp"))
    Path.join(versioned_dir(home), "launch")
  end

  # A `node` that prints its name and argv, `|`-separated.
  defp fake_node(dir, name) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "node")
    File.write!(path, ~s(#!/bin/sh\nIFS='|'; echo "#{name}|$*"\n))
    File.chmod!(path, 0o755)
    path
  end

  # A package tarball on local disk, as a manifest row with a file:// URL and
  # its real sha512 integrity.
  defp tarball_row(home, path, files, platform \\ []) do
    src = Path.join(home, "src-#{System.unique_integer([:positive])}")

    for {name, body} <- files do
      File.mkdir_p!(Path.dirname(Path.join([src, "package", name])))
      File.write!(Path.join([src, "package", name]), body)
    end

    tgz = src <> ".tgz"
    {_, 0} = System.cmd("tar", ["czf", tgz, "-C", src, "package"])
    sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, File.read!(tgz)))

    Enum.join(
      [
        path,
        "file://" <> tgz,
        sri,
        Keyword.get(platform, :os, "-"),
        Keyword.get(platform, :cpu, "-"),
        Keyword.get(platform, :libc, "-")
      ],
      "\t"
    )
  end

  defp host_cpu do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "aarch64" <> _ -> "arm64"
      _ -> "x64"
    end
  end
end
