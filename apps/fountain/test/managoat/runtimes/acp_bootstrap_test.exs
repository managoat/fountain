defmodule Managoat.Runtimes.ACPBootstrapTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.ACP
  alias Managoat.Sandbox

  setup :verify_on_exit!

  test "native runtimes preserve argv without sandbox I/O" do
    for runtime <- ["gemini"] do
      {program, args} = ACP.command(runtime)
      assert ACP.bootstrap_command(runtime, program, args) == {program, args}
    end
  end

  test "unknown runtimes cannot silently skip preparation" do
    assert_raise ArgumentError, fn -> ACP.bootstrap_command("unknown", "program", []) end
  end

  test "both package runtimes use the standalone installer's exact script" do
    for runtime <- ["claude", "codex"] do
      {"bash", ["-c", wrapper, "acp-bootstrap", installer, "program", literal]} =
        ACP.bootstrap_command(runtime, "program", [~S[quotes ' " $(exit 91)]])

      assert literal == ~S[quotes ' " $(exit 91)]
      refute wrapper =~ literal
      assert {"", 0} = System.cmd("bash", ["-n", "-c", wrapper])
      assert {"", 0} = System.cmd("bash", ["-n", "-c", installer])

      stub(Sandbox, :write_file, fn :handle, _path, _body -> :ok end)

      expect(Sandbox, :exec, fn :handle, "bash", ["-lc", script], _opts ->
        assert script == installer
        assert script =~ ACP.adapter_spec(runtime)
        {:ok, "", 0}
      end)

      assert :ok = ACP.install(:handle, runtime, [])
    end
  end

  @tag :tmp_dir
  test "setup cannot consume protocol input, its output is stderr, and argv remains literal",
       %{tmp_dir: dir} do
    # Run the production wrapper with a fixture installer. This exercises shell
    # stream/argv/exit semantics without fetching npm packages or touching /home.
    installer = ~S"""
    if read -r stolen; then exit 91; fi
    printf 'setup stdout\n'
    printf 'setup stderr\n' >&2
    cd /
    export BOOTSTRAP_FIXTURE_VALUE=changed
    """

    adapter = ~S"""
    printf '%s\n' "$1" "$BOOTSTRAP_FIXTURE_VALUE" "$PWD"
    IFS= read -r request
    printf '%s\n' "$request"
    exit 7
    """

    literal = ~S[quotes ' " $(exit 91)]
    command = fixture_command(installer, "bash", ["-c", adapter, "adapter", literal])

    assert {output, 7, errors} = run_fixture(command, dir)
    assert output == "#{literal}\noriginal\n#{dir}\n{\"jsonrpc\":\"2.0\"}\n"
    assert errors == "setup stdout\nsetup stderr\n"
  end

  @tag :tmp_dir
  test "failed setup preserves its status and never starts the adapter", %{tmp_dir: dir} do
    command = fixture_command("printf 'setup failed\\n'; exit 23", "bash", ["-c", "echo BAD"])
    assert {"", 23, "setup failed\n"} = run_fixture(command, dir)
  end

  defp fixture_command(installer, program, args) do
    {"bash", ["-c", wrapper, name, _real_installer | argv]} =
      ACP.bootstrap_command("claude", program, args)

    {"bash", ["-c", wrapper, name, installer | argv]}
  end

  defp run_fixture({program, args}, dir) do
    on_exit(fn -> File.rm_rf!(dir) end)
    input = Path.join(dir, "input")
    errors = Path.join(dir, "stderr")
    File.write!(input, "{\"jsonrpc\":\"2.0\"}\n")

    launcher = ~S"""
    input=$1
    errors=$2
    shift 2
    exec "$@" < "$input" 2> "$errors"
    """

    {output, status} =
      System.cmd("bash", ["-c", launcher, "fixture", input, errors, program | args],
        cd: dir,
        env: [{"BOOTSTRAP_FIXTURE_VALUE", "original"}]
      )

    {output, status, File.read!(errors)}
  end
end
