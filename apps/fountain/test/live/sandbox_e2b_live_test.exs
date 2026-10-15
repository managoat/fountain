defmodule Managoat.Sandbox.E2BLiveTest do
  # The E2B adapter against a real e2b.dev account. Excluded from `mix test`
  # (test_helper.exs excludes :live); run it with
  #
  #     E2B_API_KEY=... E2B_TEMPLATE=fountain mix test --only live test/live/sandbox_e2b_live_test.exs
  #
  # It creates real, billed sandboxes. Every one carries this run's name prefix
  # and is destroyed in `on_exit`, whether its test passed or not, and the
  # sweep at the end destroys anything else under the prefix a crashed test
  # left behind.
  #
  # The stubbed suites (e2b_test.exs, e2b/*_test.exs) pin what the adapter
  # sends. This one pins what E2B does with it, which is what #2574 (stdin by
  # tag 404s after a pause and resume) showed the stubs cannot know.
  use Managoat.Sandbox.ConformanceCase,
    adapter: Managoat.Sandbox.E2B,
    name: {Managoat.Sandbox.E2BLiveTest, :live_name, []},
    moduletag: :live,
    timeout: 30_000,
    spawn_opts: [detachable: true],
    fixtures: %{
      exec_ok: {"bash", ["-lc", "echo hello"], "hello"},
      exec_fail: {"bash", ["-lc", "echo oops; exit 3"], 3},
      spawn_ok: {"bash", ["-lc", "echo hello"]},
      # Prints a line, then echoes stdin as it arrives until EOF, exit 0.
      spawn_stay: {"bash", ["-c", "echo ready; exec cat"]}
    }

  alias Managoat.Sandbox.E2B
  alias Managoat.Sandbox.NetworkPolicy

  @moduletag timeout: 300_000

  @prefix "msb-live-#{System.os_time(:second)}-#{System.unique_integer([:positive])}"

  def live_name, do: "#{@prefix}-#{System.unique_integer([:positive])}"

  setup_all do
    api_key = System.get_env("E2B_API_KEY")

    if api_key in [nil, ""] do
      raise "E2B_API_KEY is not set; the live suite talks to a real e2b.dev account"
    end

    previous = Application.get_env(:fountain, E2B)

    Application.put_env(:fountain, E2B,
      api_key: api_key,
      base_url: env("E2B_BASE_URL", "https://api.e2b.app"),
      template: env("E2B_TEMPLATE", "fountain"),
      user: env("E2B_USER", "sprite"),
      timeout_ms: 60_000
    )

    on_exit(fn ->
      sweep()

      if previous,
        do: Application.put_env(:fountain, E2B, previous),
        else: Application.delete_env(:fountain, E2B)
    end)

    :ok
  end

  defp env(name, default) do
    case System.get_env(name) do
      blank when blank in [nil, ""] -> default
      value -> value
    end
  end

  # Anything under this run's prefix, including what a crashed test left.
  defp sweep do
    case E2B.list_all_names() do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, @prefix) do
          E2B.destroy(E2B.build_handle(name))
        end

      {:error, reason} ->
        IO.warn("live sweep could not list E2B sandboxes: #{inspect(reason)}")
    end
  end

  defp live_handle do
    {:ok, handle} = E2B.create(live_name(), [])
    on_exit(fn -> E2B.destroy(handle) end)
    handle
  end

  defp stay_command(handle) do
    {cmd, args} = @fixtures.spawn_stay

    {:ok, command} =
      E2B.spawn(handle, cmd, args, owner: self(), stdin: true, detachable: true)

    ref = command.ref
    assert_receive {:stdout, %{ref: ^ref}, ready}, 30_000
    assert ready =~ "ready"
    command
  end

  defp assert_echo(command, line) do
    ref = command.ref
    assert :ok = E2B.write_stdin(command, line <> "\n")
    assert_receive {:stdout, %{ref: ^ref}, echoed}, 30_000
    assert echoed =~ line
  end

  describe "E2B live: a paused and resumed sandbox" do
    # #2574: after a pause and resume, envd 404s stdin addressed by tag. A
    # process started after the resume must still take input, which is the
    # agent process every turn after a park starts.
    test "a process started after resume takes stdin and exits on EOF" do
      handle = live_handle()
      assert :ok = E2B.suspend(handle)
      assert {:ok, %{status: :suspended}} = E2B.get(handle)
      assert {:ok, resumed} = E2B.resume(handle)

      command = stay_command(resumed)
      assert_echo(command, "after-resume")

      ref = command.ref
      assert :ok = E2B.close_stdin(command)
      assert_receive {:exit, %{ref: ^ref}, 0}, 30_000
    end

    test "the disk survives the pause" do
      handle = live_handle()
      assert :ok = E2B.write_file(handle, "/tmp/live-proof", "survives\n", [])
      assert :ok = E2B.suspend(handle)
      assert {:ok, resumed} = E2B.resume(handle)
      assert {:ok, "survives\n", 0} = E2B.exec(resumed, "cat", ["/tmp/live-proof"], [])
    end

    # A paused sandbox under a `ready` row is what a missed TTL heartbeat
    # leaves; the next operation resumes it rather than failing.
    test "an exec on a paused sandbox resumes it first" do
      handle = live_handle()
      assert :ok = E2B.suspend(handle)
      assert {:ok, out, 0} = E2B.exec(handle, "bash", ["-lc", "echo awake"], [])
      assert out =~ "awake"
      assert {:ok, %{status: :running}} = E2B.get(handle)
    end

    # A process started before the pause is still there after it (E2B
    # snapshots memory), and a new owner attaching to it gets its output
    # from byte zero, which is how a woken conversation reattaches.
    test "attach after resume replays a pre-pause session from byte zero" do
      handle = live_handle()
      command = stay_command(handle)
      assert_echo(command, "before-pause")
      assert :ok = E2B.stop_command(command)

      assert :ok = E2B.suspend(handle)
      assert {:ok, resumed} = E2B.resume(handle)

      assert {:ok, sessions} = E2B.list_sessions(resumed)
      tag = command.private.tag
      assert Enum.any?(sessions, &(&1.id == tag))

      assert {:ok, attached} = E2B.attach(resumed, tag, owner: self(), stdin: true)
      ref = attached.ref
      replayed = collect_stdout(ref, "before-pause", "")
      assert replayed =~ "ready"
      assert replayed =~ "before-pause"

      assert_echo(attached, "after-attach")
      assert :ok = E2B.close_stdin(attached)
      assert_receive {:exit, %{ref: ^ref}, 0}, 30_000
    end
  end

  describe "E2B live: files and exec" do
    test "write_file lands as the configured user and reads back byte for byte" do
      handle = live_handle()
      body = :crypto.strong_rand_bytes(256) |> Base.encode64()
      assert :ok = E2B.write_file(handle, "/home/sprite/live-proof.txt", body, [])
      assert {:ok, ^body, 0} = E2B.exec(handle, "cat", ["/home/sprite/live-proof.txt"], [])

      assert {:ok, owner, 0} =
               E2B.exec(handle, "stat", ["-c", "%U", "/home/sprite/live-proof.txt"], [])

      assert String.trim(owner) == env("E2B_USER", "sprite")
    end

    test "a finite exec timeout is enforced" do
      handle = live_handle()
      assert {:error, _} = E2B.exec(handle, "sleep", ["30"], timeout: 2_000)
    end
  end

  describe "E2B live: egress" do
    # Default-deny is the property ADR 0018 credits E2B with: an allowlist
    # admits its hosts and nothing else.
    test "the allowlist admits named hosts and denies the rest" do
      handle = live_handle()
      assert :ok = E2B.apply_network_policy(handle, %NetworkPolicy{allow: ["example.com"]})
      assert curl(handle, "https://example.com") == "200"
      refute curl(handle, "https://www.iana.org") == "200"

      assert :ok = E2B.apply_network_policy(handle, %NetworkPolicy{allow: []})
      refute curl(handle, "https://example.com") == "200"
    end
  end

  defp curl(handle, url) do
    {:ok, out, _code} =
      E2B.exec(
        handle,
        "bash",
        ["-lc", "curl -s -o /dev/null -w '%{http_code}' --max-time 10 #{url} || true"],
        timeout: 30_000
      )

    String.trim(out)
  end

  defp collect_stdout(ref, until, acc) do
    if acc =~ until do
      acc
    else
      receive do
        {:stdout, %{ref: ^ref}, data} -> collect_stdout(ref, until, acc <> data)
      after
        30_000 -> flunk("replay never reached #{inspect(until)}; got #{inspect(acc)}")
      end
    end
  end
end
