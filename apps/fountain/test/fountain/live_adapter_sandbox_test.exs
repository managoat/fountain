defmodule Fountain.LiveAdapterSandboxTest do
  # The live adapter suite's provider selection and its Sprites checks' pure
  # parts. The suite itself is billed and runs only when asked; these keep the
  # parts that decide where it runs, what it names and what it destroys honest
  # in the ordinary suite.
  use ExUnit.Case, async: true

  alias Fountain.LiveAdapterSandbox, as: S

  describe "mode/1" do
    test "E2B unless Sprites is asked for, so the release gate keeps its provider" do
      assert S.mode(nil) == :e2b
      assert S.mode("") == :e2b
      assert S.mode("  ") == :e2b
      assert S.mode("e2b") == :e2b
      assert S.mode("sprites") == :sprites
      assert S.mode(" sprites\n") == :sprites
    end

    test "anything else is refused rather than read as E2B" do
      for value <- ["Sprites", "sprite", "loam", "true"] do
        assert_raise ArgumentError, ~r/LIVE_ADAPTER_SANDBOX/, fn -> S.mode(value) end
      end
    end
  end

  describe "names" do
    test "E2B keeps the names its workflow's cleanup step matches" do
      assert S.run_prefix(:e2b) == "fountain-live-adapter-"
      assert S.name(:e2b, S.run_prefix(:e2b), "codex") =~ ~r/\Afountain-live-adapter-codex-\d+\z/
    end

    test "a Sprites run's names carry its run id and only the runtime after it" do
      prefix = S.run_prefix({:sprites, "1792175924-0a1b2c3d"})
      assert prefix == "fountain-live-adapter-sprites-1792175924-0a1b2c3d-"
      assert S.name(:sprites, prefix, "codex") == prefix <> "codex"
      assert S.name(:sprites, prefix, "claude") == prefix <> "claude"
    end

    test "two runs never share a prefix, and neither is E2B's" do
      a = S.run_prefix({:sprites, S.run_id()})
      b = S.run_prefix({:sprites, S.run_id()})
      assert a != b
      refute String.starts_with?(S.name(:e2b, S.run_prefix(:e2b), "codex"), a)
      assert byte_size(S.name(:sprites, a, "claude")) <= 63
    end

    test "a run id that could widen or break the prefix is refused" do
      for id <- ["", "UPPER", "a b", "a--b", "-a", "a-", "a/b", "a*"] do
        assert_raise ArgumentError, fn -> S.run_prefix({:sprites, id}) end
      end
    end
  end

  test "the Sprites config does not publish the test sprite's URL" do
    config = S.sprites_config("tok", "https://api.sprites.dev")
    assert config[:public_urls] == false
    assert config[:token] == "tok"
    assert config[:base_url] == "https://api.sprites.dev"
  end

  describe "processes" do
    @image "/home/sprite/.codex/packages/standalone/releases/0.162.1-x86_64-unknown-linux-musl/bin/codex"
    @dir "/home/sprite/.local/share/managoat/acp/codex-acp@2.2.2"

    test "parse /proc's listing and find what runs a path, natively or under node" do
      out =
        Enum.join(
          [
            "1\t/sbin/init",
            "40\tnode\x1f#{@dir}/node_modules/@agentclientprotocol/codex-acp/dist/index.js",
            "41\t#{@image}\x1fapp-server",
            "42\t/usr/bin/node\x1f#{@image}\x1f--flag",
            "43\tbash\x1f-c\x1fecho #{@image}",
            "garbage line",
            "x\tnot-a-pid"
          ],
          "\n"
        )

      procs = S.parse_processes(out)
      assert Enum.map(procs, & &1.pid) == [1, 40, 41, 42, 43]
      assert Enum.map(S.running(procs, @image), & &1.pid) == [41, 42]
      assert S.running_under(procs, @dir <> "/node_modules/@openai/codex-") == []
      assert Enum.map(S.running_under(procs, @dir <> "/"), & &1.pid) == [40]
    end

    test "the listing runs in bash and sees this test's own process" do
      {out, 0} = System.cmd("bash", ["-c", S.process_listing()])
      procs = S.parse_processes(out)
      assert Enum.any?(procs, &(&1.pid == String.to_integer(System.pid())))
    end
  end

  describe "install_report/3" do
    @tag :tmp_dir
    test "reports the recorded image executable and no bundled CLI", %{tmp_dir: tmp} do
      {report, dir} = fake_install(tmp, image: true, bundled: false)

      assert %{
               dir: ^dir,
               executable_ok?: true,
               version: "codex-cli 0.162.1",
               bundled: []
             } = report

      assert report.executable == Path.join(tmp, "image/codex")
    end

    @tag :tmp_dir
    test "reports the bundled platform package and no executable", %{tmp_dir: tmp} do
      {report, _dir} = fake_install(tmp, image: false, bundled: true)

      assert %{executable: nil, executable_ok?: false, version: nil} = report
      assert report.bundled == ["node_modules/@openai/codex-linux-x64"]
    end

    @tag :tmp_dir
    test "a recorded executable that is gone is reported as not executable", %{tmp_dir: tmp} do
      {_report, dir} = fake_install(tmp, image: true, bundled: false)
      File.rm!(Path.join(tmp, "image/codex"))
      report = run_report(tmp, dir)
      assert report.executable == Path.join(tmp, "image/codex")
      refute report.executable_ok?
    end
  end

  # An install laid out as `Managoat.Runtimes.ACP` leaves one: a PATH link to
  # `<dir>/launch`, the marker, and node_modules, under a fake /home/sprite.
  defp fake_install(tmp, opts) do
    dir = Path.join(tmp, ".local/share/managoat/acp/codex-acp@2.2.2")
    File.mkdir_p!(Path.join(dir, "node_modules/@openai/codex"))
    File.write!(Path.join(dir, "launch"), "#!/bin/sh\n")
    File.mkdir_p!(Path.join(tmp, ".local/bin"))
    File.ln_s!(Path.join(dir, "launch"), Path.join(tmp, ".local/bin/codex-acp"))

    if opts[:image] do
      image = Path.join(tmp, "image/codex")
      File.mkdir_p!(Path.dirname(image))
      File.write!(image, "#!/bin/sh\necho 'codex-cli 0.162.1'\n")
      File.chmod!(image, 0o755)
      File.write!(Path.join(dir, ".codex-executable"), image <> "\n")
    end

    if opts[:bundled], do: File.mkdir_p!(Path.join(dir, "node_modules/@openai/codex-linux-x64"))

    {run_report(tmp, dir), dir}
  end

  defp run_report(tmp, _dir) do
    script =
      S.install_report("codex-acp", ".codex-executable", "node_modules/@openai/codex-")
      |> String.replace("/home/sprite", tmp)

    {out, 0} = System.cmd("bash", ["-c", script])
    S.parse_install_report(out)
  end
end
