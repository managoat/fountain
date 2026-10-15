defmodule Managoat.Sandbox.SpritesLiveTest do
  # The Sprites adapter against a real sprites.dev organization. Excluded from
  # `mix test` (test_helper.exs excludes :live); run it with
  #
  #     SPRITES_TOKEN=... mix test --only live test/live/sandbox_sprites_live_test.exs
  #
  # It creates real, billed sprites. Every one carries this run's name prefix,
  # `msb-live-`, and is destroyed in `on_exit` whether its test passed or not;
  # the sweep at the end destroys anything else under the prefix. Sprites
  # tokens cannot be scoped to a prefix, so the token reaches every sprite in
  # its organization; nothing here touches a name outside the prefix.
  #
  # The stubbed suites (sprites_test.exs, sprites/*_test.exs) pin what the
  # adapter sends and how it reads the SDK's answers. This one pins what
  # Sprites does: a fresh sprite refusing work for its first seconds (#2491),
  # cold wakes keeping the disk, public URLs, checkpoints and egress rules.
  use Managoat.Sandbox.ConformanceCase,
    adapter: Managoat.Sandbox.Sprites,
    name: {Managoat.Sandbox.SpritesLiveTest, :live_name, []},
    moduletag: :live,
    timeout: 60_000,
    fixtures: %{
      exec_ok: {"bash", ["-lc", "echo hello"], "hello"},
      exec_fail: {"bash", ["-lc", "echo oops; exit 3"], 3},
      spawn_ok: {"bash", ["-lc", "echo hello"]},
      # Prints a line, then echoes stdin as it arrives until EOF, exit 0.
      spawn_stay: {"bash", ["-c", "echo ready; exec cat"]}
    }

  alias Managoat.Sandbox.NetworkPolicy
  alias Managoat.Sandbox.Retry
  alias Managoat.Sandbox.Sprites

  @moduletag timeout: 600_000

  @prefix "msb-live-#{System.os_time(:second)}-#{System.unique_integer([:positive])}"

  def live_name, do: "#{@prefix}-#{System.unique_integer([:positive])}"

  setup_all do
    token = System.get_env("SPRITES_TOKEN")

    if token in [nil, ""] do
      raise "SPRITES_TOKEN is not set; the live suite talks to a real sprites.dev organization"
    end

    previous = Application.get_env(:fountain, Sprites)

    Application.put_env(:fountain, Sprites,
      token: token,
      base_url: env("SPRITES_BASE_URL", "https://api.sprites.dev"),
      timeout_ms: 60_000,
      # Off, as in production: Fountain creates no checkpoints there. The
      # checkpoint test below turns it on for itself.
      checkpoint_creation_enabled: false
    )

    on_exit(fn ->
      sweep()

      if previous,
        do: Application.put_env(:fountain, Sprites, previous),
        else: Application.delete_env(:fountain, Sprites)
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
    case Sprites.list_all_names() do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, @prefix) do
          Sprites.destroy(Sprites.build_handle(name))
        end

      {:error, reason} ->
        IO.warn("live sweep could not list sprites: #{inspect(reason)}")
    end
  end

  # A created sprite that has answered one exec: what Fountain's provisioning
  # waits for (through Retry) before it does anything else.
  defp ready_handle do
    {:ok, handle} = Sprites.create(live_name(), [])
    on_exit(fn -> Sprites.destroy(handle) end)

    assert {:ok, _out, 0} =
             Retry.with_backoff(fn -> Sprites.exec(handle, "true", [], timeout: 30_000) end,
               attempts: 8,
               base_ms: 1_000
             )

    handle
  end

  defp sh(handle, script, opts \\ []) do
    Sprites.exec(handle, "bash", ["-lc", script], Keyword.put_new(opts, :timeout, 60_000))
  end

  describe "Sprites live: a fresh sprite" do
    # #2491: a sprite answers 503 for its first seconds. The adapter must say
    # so as a transient error, which is what lets Retry ride it out, rather
    # than as a definitive one that fails a provision.
    test "its first exec either works or fails transiently, and Retry gets through" do
      {:ok, handle} = Sprites.create(live_name(), [])
      on_exit(fn -> Sprites.destroy(handle) end)

      case Sprites.exec(handle, "true", [], timeout: 30_000) do
        {:ok, _out, 0} -> :ok
        {:error, reason} -> assert Retry.transient?(reason), "not transient: #{inspect(reason)}"
      end

      assert {:ok, _out, 0} =
               Retry.with_backoff(fn -> Sprites.exec(handle, "true", [], timeout: 30_000) end,
                 attempts: 8,
                 base_ms: 1_000
               )
    end

    test "write_file lands where exec reads it, byte for byte" do
      handle = ready_handle()
      body = :crypto.strong_rand_bytes(256) |> Base.encode64()
      assert :ok = Sprites.write_file(handle, "/home/sprite/live-proof.txt", body, [])
      assert {:ok, ^body, 0} = Sprites.exec(handle, "cat", ["/home/sprite/live-proof.txt"], [])
    end

    test "a finite exec timeout is enforced" do
      handle = ready_handle()
      assert {:error, _} = Sprites.exec(handle, "sleep", ["30"], timeout: 2_000)
    end
  end

  describe "Sprites live: going cold" do
    # Sprites stop on their own after about 30 s without activity; `suspend/1`
    # is a no-op on purpose. A stopped sprite reports `warm` and later, on the
    # provider's own schedule, `cold` (one stayed `warm` for 5 minutes on
    # 2026-10-06), so the test waits for either. The next exec wakes it, and
    # the disk has to be there when it does.
    test "a sprite left idle wakes on the next exec with its disk intact" do
      handle = ready_handle()
      assert :ok = Sprites.write_file(handle, "/home/sprite/before-idle", "kept\n", [])
      assert :ok = Sprites.suspend(handle)

      status = wait_until_idle(handle, 180_000)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Retry.with_backoff(fn -> sh(handle, "cat /home/sprite/before-idle") end,
            attempts: 6,
            base_ms: 2_000
          )
        end)

      assert {:ok, "kept\n", 0} = result
      IO.puts("\n    sprite went #{status}; first exec after it took #{div(elapsed_us, 1000)} ms")
    end
  end

  defp wait_until_idle(handle, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms

    Stream.repeatedly(fn ->
      Process.sleep(5_000)
      {:ok, %{raw: raw}} = Sprites.get(handle)
      raw["status"]
    end)
    |> Enum.find(fn status ->
      status != "running" or System.monotonic_time(:millisecond) > deadline
    end)
    |> tap(fn status ->
      assert status != "running", "sprite never stopped in #{budget_ms} ms"
    end)
  end

  describe "Sprites live: public URL" do
    # #725: a sandbox's URL is opened to the public at create, so a human the
    # agent sends there needs no platform credential.
    test "a server on port 8080 answers at the public URL without a token" do
      handle = ready_handle()
      assert {:ok, url} = Sprites.public_url(handle)

      marker = "live-#{System.unique_integer([:positive])}"
      assert {:ok, _, 0} = sh(handle, "mkdir -p /tmp/www && echo #{marker} > /tmp/www/index.html")

      {:ok, server} =
        Sprites.spawn(handle, "bash", ["-lc", "cd /tmp/www && exec python3 -m http.server 8080"],
          owner: self(),
          stdin: false,
          detachable: true
        )

      on_exit(fn -> Sprites.stop_command(server) end)

      body =
        Enum.find_value(1..20, fn _ ->
          Process.sleep(1_500)

          case Req.get(url, retry: false, receive_timeout: 10_000) do
            {:ok, %{status: 200, body: body}} when is_binary(body) -> if body =~ marker, do: body
            _ -> nil
          end
        end)

      assert body, "#{url} never served the page without a token"
    end
  end

  describe "Sprites live: checkpoints" do
    test "a restore puts the checkpointed file back" do
      config = Application.get_env(:fountain, Sprites)

      Application.put_env(
        :fountain,
        Sprites,
        Keyword.put(config, :checkpoint_creation_enabled, true)
      )

      on_exit(fn -> Application.put_env(:fountain, Sprites, config) end)

      handle = ready_handle()
      assert {:ok, _, 0} = sh(handle, "echo original > /home/sprite/cp-proof")
      assert {:ok, checkpoint_id} = Sprites.create_checkpoint(handle, comment: "msb-live")
      assert is_binary(checkpoint_id)

      assert {:ok, _, 0} = sh(handle, "echo changed > /home/sprite/cp-proof")
      assert :ok = Sprites.restore_checkpoint(handle, checkpoint_id)

      assert {:ok, "original\n", 0} =
               Retry.with_backoff(fn -> sh(handle, "cat /home/sprite/cp-proof") end,
                 attempts: 6,
                 base_ms: 2_000
               )
    end
  end

  describe "Sprites live: egress" do
    # Sprites enforce by domain rule; an empty allowlist must compile to an
    # explicit deny-all, because a bare `rules: []` means no enforcement.
    test "the allowlist admits named hosts and denies the rest" do
      handle = ready_handle()
      assert :ok = Sprites.apply_network_policy(handle, %NetworkPolicy{allow: ["example.com"]})
      assert eventually_curl(handle, "https://example.com", &(&1 == "200"))
      assert eventually_curl(handle, "https://www.iana.org", &(&1 != "200"))

      assert :ok = Sprites.apply_network_policy(handle, %NetworkPolicy{allow: []})
      assert eventually_curl(handle, "https://example.com", &(&1 != "200"))
    end
  end

  # A policy takes a moment to reach the sprite's proxy; poll briefly rather
  # than assert on the first request.
  defp eventually_curl(handle, url, ok?) do
    Enum.find_value(1..6, fn attempt ->
      if attempt > 1, do: Process.sleep(2_000)

      {:ok, out, _} =
        sh(handle, "curl -s -o /dev/null -w '%{http_code}' --max-time 10 #{url} || true")

      if ok?.(String.trim(out)), do: true
    end) || false
  end
end
