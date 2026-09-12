defmodule Fountain.ConversationServerCase do
  @moduledoc """
  Harness for driving a real `ConversationServer` in tests.

  The module has had no tests of its own since launch — 1,183 lines covering
  provisioning, reattach, turn handling and teardown, holding tenant secrets and
  spending money, excluded from the coverage gate and `Mimic.copy`'d out of
  every caller's tests. The reason it stayed untested is that starting one
  reaches for the Sprites API, the filesystem inside a sprite, a runtime CLI and
  OpenTelemetry.

  This stubs that boundary once, permissively, so an individual test only has to
  express the thing it cares about. `stub/3` is used rather than `expect/3` so
  unstated calls are allowed; tests that care about a specific interaction
  override it.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Fountain.DataCase, async: false
      use Mimic

      import Fountain.ConversationServerCase

      alias Fountain.Conversations
      alias Fountain.Conversations.ConversationServer

      # The server runs in its own process, so per-process stubs set from the
      # test would not apply to it. Global mode is safe here because these
      # modules are async: false, and ExUnit runs those one at a time after the
      # async ones have finished.
      setup :set_mimic_global

      # The server also needs to reach the sandbox from its own process.
      setup do
        Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
        :ok
      end
    end
  end

  @doc """
  Stub every external boundary a provision touches, on the happy path.

  The whole sandbox seam is the `Managoat.Sandbox.Sprites` adapter — the
  server never names the SDK anymore. Returns the handle the stubbed
  `create/2` will hand back.
  """
  def stub_happy_sprite(name \\ "test-sprite") do
    handle = Managoat.Sandbox.Sprites.build_handle(name)

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts -> {:ok, handle} end)
    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)

    Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :running, raw: %{}}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _handle, _cmd, _args, _opts ->
      {:ok, "", 0}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _handle, _path, _data, _opts -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _handle -> {:ok, []} end)
    Mimic.stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _handle, _policy -> :ok end)

    # A turn's spawn fails cleanly unless the test stubs it — mirroring the
    # pre-facade behavior where spawning against the fake sprite errored and
    # the turn was marked failed. Tests exercising turns re-stub spawn (and
    # write_stdin/close_stdin where their turn writes; the #603 tests rely on
    # the adapter's REAL write path, so those stay unstubbed here).
    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _handle, _cmd, _args, _opts ->
      {:error, {:unavailable, :spawn_not_stubbed}}
    end)

    Mimic.stub(Fountain.SandboxSkills, :mount, fn _handle, _runtime, _skills -> :ok end)

    Mimic.stub(Fountain.SandboxSkills, :reconcile, fn _handle, _runtime, _skills, _previous ->
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _s, _e -> :ok end)

    Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :apply_network_policy, fn _s, _e, _c ->
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :clone_repositories, fn _s,
                                                                            _e,
                                                                            _sec,
                                                                            _env,
                                                                            _c ->
      :ok
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :create_checkpoint, fn _s, _e ->
      {:error, :no_env}
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :restore_checkpoint, fn _s, _c ->
      {:error, :no_checkpoint}
    end)

    # Per-tenant crypto is exercised in its own tests; here it only needs to
    # succeed so provisioning can proceed.
    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:ok, <<0::256>>} end)
    Mimic.stub(Fountain.InferenceCredentials, :decrypted_for_user, fn _u, _k -> {:ok, %{}} end)

    # `load_tenant_state/2` reads through `decrypted_for/3` since ADR 0053
    # decision 3, and Mimic does not intercept a module's call to itself — so
    # stubbing only `decrypted_for_user/2` would leave the real query running
    # and hand every test an empty credential map. Delegating rather than
    # answering means a test that overrides `decrypted_for_user/2` (three do)
    # is still honoured, whether or not the agent names a set.
    Mimic.stub(Fountain.InferenceCredentials, :decrypted_for, fn u, _set_id, k ->
      Fountain.InferenceCredentials.decrypted_for_user(u, k)
    end)

    handle
  end

  @doc """
  Start a real ConversationServer for `conv` and wait for it to settle.

  Started outside Horde and unlinked, so a server that legitimately stops —
  which the failure paths do — doesn't take the test process with it.
  """
  def start_server(conv, opts \\ []) do
    runtime = Keyword.get(opts, :runtime, Managoat.Runtimes.Testing.FakeRuntime)
    Managoat.Runtimes.Testing.FakeRuntime.observe(self())

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: runtime
    ]

    {:ok, pid} = GenServer.start(Fountain.Conversations.ConversationServer, args)
    ref = Process.monitor(pid)

    # The prompt is delivered out of band, exactly as production does it: it is
    # not a start_link argument, because Horde replays a stored child spec on
    # every redistribution and would re-run the prompt on each deploy. Since
    # #367 the public API delivers to the pid, so this harness — whose servers
    # are outside Horde and invisible to the registry — exercises the exact
    # production path.
    case Keyword.get(opts, :initial_prompt) do
      nil ->
        :ok

      prompt ->
        Fountain.Conversations.ConversationServer.queue_initial_prompt(
          pid,
          prompt,
          Keyword.get(opts, :images, [])
        )
    end

    # handle_continue(:provision) runs before any call is answered, so a
    # synchronous call is enough to know provisioning has finished.
    settled =
      try do
        _ = :sys.get_state(pid)
        :alive
      catch
        :exit, _ -> :stopped
      end

    {pid, ref, settled}
  end

  @doc "Wait for a monitored server to stop, or fail the test."
  def assert_stopped(ref, timeout \\ 2_000) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> reason
    after
      timeout -> raise "expected the ConversationServer to stop, but it is still running"
    end
  end
end
