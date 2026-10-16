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
    test "default_env/2 exports the key, workspace trust and HOME=/tmp, and the last two without a key" do
      trust = {"GEMINI_CLI_TRUST_WORKSPACE", "true"}

      assert Gemini.default_env(nil, %{gemini_api_key: "g"}) ==
               [{"GEMINI_API_KEY", "g"}, trust, {"HOME", "/tmp"}]

      assert Gemini.default_env(nil, %{gemini_api_key: ""}) == [trust, {"HOME", "/tmp"}]
      assert Gemini.default_env(nil, %{}) == [trust, {"HOME", "/tmp"}]
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
      assert opts[:stderr_to_stdout]
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

    test "codex writes its manifest and installs the same way" do
      test = self()

      expect(Sandbox, :write_file, fn @handle, path, body ->
        send(test, {:manifest, path, body})
        :ok
      end)

      expect(Sandbox, :exec, fn _h, _c, ["-lc", script], _o ->
        assert script =~ "dir=/home/sprite/.local/share/managoat/acp/codex-acp@2.2.2"
        assert script =~ "link=/home/sprite/.local/bin/codex-acp"
        assert script =~ "@agentclientprotocol/codex-acp@2.2.2"
        {:ok, "", 0}
      end)

      assert :ok = ACP.install(@handle, "codex", [])

      assert_receive {:manifest, path, body}
      assert path == "/home/sprite/.local/share/managoat/acp/codex-acp@2.2.2.tsv"
      assert body =~ "node_modules/@agentclientprotocol/codex-acp\thttps://"

      # The platform package installs under its alias, where the bundled
      # codex.js resolves it, from the tarball it is published as.
      assert body =~
               ~r{^node_modules/@openai/codex-linux-x64\thttps://registry\.npmjs\.org/@openai/codex/-/codex-[\d.]+-linux-x64\.tgz\tsha512-\S+\tlinux\tx64\t-$}m
    end

    test "every adapter Managoat installs has a manifest of its exact pin" do
      for runtime <- ACP.supported_runtimes(), runtime != "gemini" do
        stub(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "", 0} end)
        test = self()

        expect(Sandbox, :write_file, fn _h, path, body ->
          send(test, {:manifest, path, body})
          :ok
        end)

        assert :ok = ACP.install(@handle, runtime, [])
        assert_receive {:manifest, path, body}
        [_, name, version] = Regex.run(~r{/([^/]+)@([^/@]+)\.tsv$}, path)

        assert body =~
                 ~r{^node_modules/@agentclientprotocol/#{name}\t\S+/#{name}-#{version}\.tgz\t}m
      end
    end

    @tag :tmp_dir
    test "an installed pin is recognised without running anything", %{tmp_dir: home} do
      target = installed_fixture(home)
      File.ln_s!(target, Path.join(home, ".local/bin/claude-agent-acp"))

      assert {out, 0, calls} = run_installer(home)
      assert calls == ""
      assert Managoat.Runtimes.InstallTiming.attributes(out) == %{"install_cache_hit" => 1}
    end

    # uutils coreutils, which the Sprites image ships as `date`, truncates the
    # *unpadded* nanoseconds for %3N: a reading taken in the first 100 ms of a
    # second keeps its leading digits and comes out up to 978 ms high, so a
    # phase boundary landing there overstated or understated its phase by up to
    # a second, and one phase outlasted the span around it (#2908). The phase
    # clock no longer goes near a truncated-nanosecond format, so a `date` that
    # reproduces the defect has nothing to corrupt.
    @tag :tmp_dir
    test "phase timings survive a date whose truncated nanoseconds run backwards", %{
      tmp_dir: home
    } do
      dir = versioned_dir(home)
      File.mkdir_p!(Path.dirname(dir))

      File.write!(
        dir <> ".tsv",
        tarball_row(home, "node_modules/@agentclientprotocol/claude-agent-acp", %{
          "dist/index.js" => "#!/usr/bin/env node\n"
        }) <> "\n"
      )

      formats = Path.join(home, "date-formats")

      shim = ~s"""
      date() {
        printf '%s\\n' "$1" >>#{formats}
        case "$1" in
          *%3N)
            # Alternate the sub-second field so consecutive readings fall
            # backwards by 899 ms, as uutils does around a second boundary.
            n=$(( $(cat #{home}/date-calls 2>/dev/null || echo 0) + 1 ))
            echo "$n" >#{home}/date-calls
            [ $(( n % 2 )) -eq 0 ] && frac=100 || frac=999
            case "$1" in
              +%s%3N) printf '%s%s\\n' "$(command date +%s)" "$frac" ;;
              *) printf '%s.%s\\n' "$(command date +%s)" "$frac" ;;
            esac
            ;;
          *) command date "$@" ;;
        esac
      }
      export -f date
      """

      assert {out, 0, ""} = run_installer(home, shim)
      attrs = Managoat.Runtimes.InstallTiming.attributes(out)

      for phase <- ~w(lock_wait image_probe manifest finalize link) do
        assert attrs["install_" <> phase <> "_ms"] in 0..180_000
      end

      assert attrs["install_manifest_ms"] > 0
      assert attrs["install_timing_suspect"] == 0
      assert attrs["install_clock_skew_max_ms"] <= 50

      # The shim still answers the per-package clock, which asks for whole
      # nanoseconds and is unaffected; nothing asked it for a truncated one.
      assert File.read!(formats) =~ "+%s%N"
      refute File.read!(formats) =~ "3N"
      refute File.exists?(Path.join(home, "date-calls"))

      assert File.read!(Path.join(dir, ".install-timing")) =~ ~r/^start \d+\.\d{3}$/m
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

      assert {out, 0, calls} = run_installer(home)
      attrs = Managoat.Runtimes.InstallTiming.attributes(out)
      assert attrs["install_cache_hit"] == 0
      assert attrs["download_attempts"] == 2
      assert attrs["download_bytes_max"] > 0

      for phase <- ~w(lock_wait image_probe manifest finalize link) do
        assert is_integer(attrs["install_" <> phase <> "_ms"])
      end

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
    test "a stalled partial fetch retries with a fresh extractor and verified bytes", %{
      tmp_dir: home
    } do
      dir = versioned_dir(home)
      File.mkdir_p!(Path.dirname(dir))
      path = "node_modules/@agentclientprotocol/claude-agent-acp"
      row = tarball_row(home, path, %{"dist/index.js" => "verified entry"})
      stale = tarball_row(home, path, %{"stale.txt" => "must not survive the retry"})
      [_, "file://" <> archive | _] = String.split(row, "\t")
      [_, "file://" <> stale_archive | _] = String.split(stale, "\t")
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 15_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          partial = File.read!(stale_archive)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(partial) + 100}\r\n\r\n" <> partial
            )

          # The real curl must time out this incomplete response, not the test.
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 15_000)
          {:ok, socket} = :gen_tcp.accept(listener, 15_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          complete = File.read!(archive)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(complete)}\r\n\r\n" <> complete
            )

          :gen_tcp.close(socket)
        end)

      row = String.replace(row, "file://" <> archive, "http://127.0.0.1:#{port}/secret-url")

      nested =
        tarball_row(home, path <> "/node_modules/nested", %{"kept.js" => "nested dependency"})

      File.write!(dir <> ".tsv", row <> "\n" <> nested <> "\n")
      started = System.monotonic_time(:millisecond)
      assert {out, 0, ""} = run_installer(home)
      Task.await(server, 20_000)
      assert System.monotonic_time(:millisecond) - started < 20_000
      assert out =~ "package=#{path} step=fetch attempt=1/3 exit=28 elapsed_ms="
      refute out =~ "secret-url"
      assert Managoat.Runtimes.InstallTiming.attributes(out)["download_attempts"] == 3
      refute out =~ "attempt=2/3"
      assert File.read!(Path.join(dir, path <> "/dist/index.js")) == "verified entry"
      refute File.exists?(Path.join(dir, path <> "/stale.txt"))

      assert File.read!(Path.join(dir, path <> "/node_modules/nested/kept.js")) ==
               "nested dependency"
    end

    @tag :tmp_dir
    test "exhausted fetches and a nonzero npm fallback retain safe diagnostics", %{tmp_dir: home} do
      dir = versioned_dir(home)
      File.mkdir_p!(Path.dirname(dir))

      File.write!(
        dir <> ".tsv",
        "node_modules/failing\tfile:///secret-missing-package\tsha512-x\t-\t-\t-\n"
      )

      assert {out, 42, calls} =
               run_installer(
                 home,
                 "npm() { echo npm >>#{home}/npm-calls; echo secret-proxy-credential >&2; return 42; }"
               )

      assert calls == "npm\n"
      assert out =~ "package=node_modules/failing step=fetch attempt=3/3"
      assert out =~ "adapter install failed: step=npm exit=42 elapsed_s="
      refute out =~ "secret-missing-package"
      refute out =~ "secret-proxy-credential"
      refute File.exists?(Path.join(dir, ".installed"))
      refute File.exists?(Path.join(home, ".local/bin/claude-agent-acp"))
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
      attrs = Managoat.Runtimes.InstallTiming.attributes(out)
      assert attrs["download_attempts"] == 1
      assert is_integer(attrs["install_npm_ms"])
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

    @tag :tmp_dir
    test "Sprites reuses a recent image CLI without fetching the native package", %{tmp_dir: home} do
      image = image_claude(home, "2.1.296")
      dir = versioned_dir(home)
      File.mkdir_p!(Path.dirname(dir))

      row =
        tarball_row(home, "node_modules/@agentclientprotocol/claude-agent-acp", %{
          "dist/index.js" => "entry"
        })

      # A selected native package whose URL cannot be fetched: reuse must skip it.
      native =
        "node_modules/@anthropic-ai/claude-agent-sdk-linux-x64\tfile:///does-not-exist\tsha512-x\tlinux\t#{host_cpu()}\tglibc,musl"

      File.write!(dir <> ".tsv", row <> "\n" <> native <> "\n")
      assert {_, 0, ""} = run_installer(home)
      assert File.read!(Path.join(dir, ".claude-executable")) == image <> "\n"
      refute File.exists?(Path.join(dir, "node_modules/@anthropic-ai/claude-agent-sdk-linux-x64"))

      node = Path.join(home, "inspect-node")
      File.write!(node, "#!/bin/sh\nprintf '%s' \"$CLAUDE_CODE_EXECUTABLE\"\n")
      File.chmod!(node, 0o755)
      File.write!(Path.join(dir, ".node"), node <> "\n")
      assert {^image, 0} = System.cmd(Path.join(dir, "launch"), [])
      assert {_, 0, ""} = run_installer(home)

      # A deleted image binary repairs the install using the bundled fallback.
      File.rm!(image)
      File.rm!(dir <> ".tsv")
      assert {_, 0, calls} = run_installer(home)
      refute calls =~ "--omit=optional"
      refute File.exists?(Path.join(dir, ".claude-executable"))
    end

    @tag :tmp_dir
    test "npm fallback also omits the binary for a suitable image CLI", %{tmp_dir: home} do
      image_claude(home, "2.1.280")
      assert {_, 0, calls} = run_installer(home)
      assert calls =~ "--omit=optional"
    end

    @tag :tmp_dir
    test "old, malformed and failing image CLIs keep the bundled binary", %{tmp_dir: root} do
      for {version, status} <- [{"2.1.279", 0}, {"unknown", 0}, {"2.1.296", 1}] do
        home = Path.join(root, "#{version}-#{status}")
        image_claude(home, version, status)
        assert {_, 0, calls} = run_installer(home)
        refute calls =~ "--omit=optional"
        refute File.exists?(Path.join(versioned_dir(home), ".claude-executable"))
      end
    end

    @tag :tmp_dir
    test "Sprites reuses a recent image codex without fetching its platform package",
         %{tmp_dir: home} do
      image = image_codex(home, "0.162.1")
      dir = versioned_dir(home, "codex")
      File.mkdir_p!(Path.dirname(dir))

      row =
        tarball_row(home, "node_modules/@agentclientprotocol/codex-acp", %{
          "dist/index.js" => "entry"
        })

      # `@openai/codex` itself is JavaScript and stays pinned; only the
      # platform package the image CLI replaces is skipped, so a URL that
      # cannot be fetched proves it was never asked for.
      wrapper =
        tarball_row(home, "node_modules/@openai/codex", %{"bin/codex.js" => "bundled"})

      platform =
        "node_modules/@openai/codex-linux-x64\tfile:///does-not-exist\tsha512-x\tlinux\t#{host_cpu()}\t-"

      File.write!(dir <> ".tsv", Enum.join([row, wrapper, platform], "\n") <> "\n")
      assert {_, 0, ""} = run_installer(home, "", "codex")
      assert File.read!(Path.join(dir, ".codex-executable")) == image <> "\n"
      refute File.exists?(Path.join(dir, "node_modules/@openai/codex-linux-x64"))
      assert File.exists?(Path.join(dir, "node_modules/@openai/codex/bin/codex.js"))

      # The launcher hands the recorded executable to the adapter as CODEX_PATH,
      # which is what `startCodexConnection` spawns instead of the bundled one.
      node = Path.join(home, "inspect-node")
      File.write!(node, "#!/bin/sh\nprintf '%s' \"$CODEX_PATH\"\n")
      File.chmod!(node, 0o755)
      File.write!(Path.join(dir, ".node"), node <> "\n")
      assert {^image, 0} = System.cmd(Path.join(dir, "launch"), [])
      assert {_, 0, ""} = run_installer(home, "", "codex")

      # A removed image binary invalidates the install, which repairs itself
      # with the bundled platform package.
      File.rm!(image)
      File.rm!(dir <> ".tsv")
      assert {_, 0, calls} = run_installer(home, "", "codex")
      refute calls =~ "--omit=optional"
      refute File.exists?(Path.join(dir, ".codex-executable"))
    end

    @tag :tmp_dir
    test "the codex npm fallback omits the platform package at the floor exactly",
         %{tmp_dir: home} do
      image_codex(home, "0.160.1")
      assert {_, 0, calls} = run_installer(home, "", "codex")
      assert calls =~ "--omit=optional"
      assert calls =~ "@agentclientprotocol/codex-acp@2.2.2"
    end

    @tag :tmp_dir
    test "old, malformed and failing image codex CLIs keep the bundled one", %{tmp_dir: root} do
      # Below the floor, a version line that is not codex's, and a binary whose
      # `--version` fails: each keeps the pinned platform package.
      for {version, status} <- [{"0.160.0", 0}, {"unknown", 0}, {"0.162.1", 1}] do
        home = Path.join(root, "#{version}-#{status}")
        image_codex(home, version, status)
        assert {_, 0, calls} = run_installer(home, "", "codex")
        refute calls =~ "--omit=optional"
        refute File.exists?(Path.join(versioned_dir(home, "codex"), ".codex-executable"))
      end
    end

    @tag :tmp_dir
    test "no image codex at all keeps the bundled one", %{tmp_dir: home} do
      assert {_, 0, calls} = run_installer(home, "", "codex")
      refute calls =~ "--omit=optional"
      refute File.exists?(Path.join(versioned_dir(home, "codex"), ".codex-executable"))
    end

    test "E2B keeps the pinned bundled CLI for both adapters" do
      for runtime <- ["claude", "codex"] do
        refute installer(runtime, :e2b) =~ "select_image_executable"
        assert installer(runtime, :sprites) =~ "select_image_executable"
      end
    end

    test "a failed install retains bounded terminal diagnostics" do
      long = String.duplicate("e", 2_500) <> "terminal failure"
      stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, long, 1} end)

      assert {:error, {:acp_adapter_install_exit, 1, out}} = ACP.install(@handle, "claude", [])
      assert byte_size(out) == 2_000
      assert String.ends_with?(out, "terminal failure")

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)
      assert {:error, {:acp_adapter_install, :unavailable}} = ACP.install(@handle, "claude", [])
    end
  end

  defp image_claude(home, version, status \\ 0) do
    image_cli(home, "claude", ".local/share/claude/versions/#{version}", [
      "#{version} (Claude Code)",
      status
    ])
  end

  # The image's own `codex`, as the Sprite image lays it out: a versioned
  # standalone release behind a `current` symlink, which is why the installer
  # resolves the link before recording what it selected.
  defp image_codex(home, version, status \\ 0) do
    image_cli(home, "codex", ".codex/packages/standalone/releases/#{version}/bin/codex", [
      "codex-cli #{version}",
      status
    ])
  end

  defp image_cli(home, name, relative, [printed, status]) do
    path = Path.join(home, relative)
    link = Path.join(home, ".local/bin/#{name}")
    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(Path.dirname(link))
    File.write!(path, "#!/bin/sh\necho '#{printed}'\nexit #{status}\n")
    File.chmod!(path, 0o755)
    File.ln_s!(path, link)
    path
  end

  # One runtime's installer, run for real under `bash -lc` with `/home/sprite`
  # moved to `home`. The home has a ~/.bash_logout that fails, as the sprite's
  # does outside a console: an `exit` at the installer's top level would turn
  # success into exit 1 (the bug a fast-path `exit 0` shipped with). npm is a
  # stub that records its call and lays out the package, so no package manager
  # runs. Answers {output, status, npm calls}.
  defp run_installer(home, overrides \\ "", runtime \\ "claude") do
    File.mkdir_p!(Path.join(home, ".local/bin"))
    File.write!(Path.join(home, ".bash_logout"), "false\n")
    calls = Path.join(home, "npm-calls")

    script = String.replace(installer(runtime, :sprites), "/home/sprite", home)

    # `node -p process.execPath` answers as a sprite's would, from an nvm tree.
    npm = ~s"""
    export PATH="#{home}/.local/bin:/usr/bin:/bin"
    node() { echo /opt/node/bin/node; }
    npm() {
      echo "npm $*" >>"#{calls}"
      local d=$3
      mkdir -p "$d/node_modules/#{package(runtime)}/dist"
      : >"$d/node_modules/#{package(runtime)}/dist/index.js"
    }
    """

    {out, status} =
      System.cmd("bash", ["-lc", npm <> overrides <> "\n" <> script],
        env: [{"HOME", home}],
        stderr_to_stdout: true
      )

    {out, status, if(File.exists?(calls), do: File.read!(calls), else: "")}
  end

  # The script `ACP.install/3` runs for `runtime` on `provider`, as it hands it
  # to the sandbox.
  defp installer(runtime, provider) do
    stub(Sandbox, :write_file, fn _h, _p, _b -> :ok end)

    stub(Sandbox, :exec, fn _h, "bash", ["-lc", script], _o ->
      send(self(), {:installer, script})
      {:ok, "", 0}
    end)

    :ok = ACP.install(%{@handle | provider: provider}, runtime, [])
    assert_received {:installer, script}
    script
  end

  @pins %{
    "claude" => {"@agentclientprotocol/claude-agent-acp", "claude-agent-acp@0.81.2"},
    "codex" => {"@agentclientprotocol/codex-acp", "codex-acp@2.2.2"}
  }

  defp package(runtime), do: @pins |> Map.fetch!(runtime) |> elem(0)

  defp versioned_dir(home, runtime \\ "claude"),
    do: Path.join(home, ".local/share/managoat/acp/#{@pins |> Map.fetch!(runtime) |> elem(1)}")

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
