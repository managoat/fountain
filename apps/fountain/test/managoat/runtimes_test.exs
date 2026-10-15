defmodule Managoat.RuntimesTest do
  # async: false — the dispatch tests unload a module out of the code server,
  # which is global.
  use ExUnit.Case, async: false

  alias Managoat.Runtimes

  @unloaded Managoat.RuntimesTest.UnloadedRuntime

  # A runtime module that exists on disk and is *not* loaded, which is what
  # every module nobody has called looks like under an escript or a release.
  #
  # Compiled here rather than reusing a real runtime because reaching this
  # state means purging the module, and purging one of the library's own
  # modules throws away the coverage cover has collected for it — the run
  # then reports a smaller suite than it ran.
  @source """
  defmodule #{inspect(@unloaded)} do
    @moduledoc false
    @behaviour Managoat.Runtimes

    @impl true
    def build_command(_agent, prompt, _mode, _session_id, _opts), do: {"echo", [prompt], []}

    @impl true
    def default_env(_agent, credentials), do: [{"UNLOADED_KEY", credentials.anthropic_api_key}]

    @impl true
    def write_config(_handle, _agent), do: {:error, :wrote_config}

    @impl true
    def prepare_sandbox(_handle, _agent, _sprite_env), do: {:error, :prepared_sandbox}

    @impl true
    def skills_root, do: "/home/sprite/.unloaded/skills"
  end
  """

  setup_all do
    dir = Fountain.TmpDir.mkdir!("managoat_runtimes_dispatch")

    for {mod, bin} <- Code.compile_string(@source),
        do: File.write!(Path.join(dir, "#{mod}.beam"), bin)

    Code.prepend_path(dir)

    on_exit(fn -> Code.delete_path(dir) end)

    :ok
  end

  setup do
    # Each test loads the module by dispatching to it, so unload it again.
    :code.purge(@unloaded)
    :code.delete(@unloaded)
    refute :erlang.module_loaded(@unloaded), "#{inspect(@unloaded)} was still loaded"
    :ok
  end

  describe "for_runtime/1" do
    test "returns {:ok, module} for known runtimes" do
      for name <- ~w(claude codex gemini) do
        assert {:ok, mod} = Runtimes.for_runtime(name)
        assert is_atom(mod)
      end

      # Removed from Fountain in 2026-10; its module went with the fold-back.
      assert {:error, _} = Runtimes.for_runtime("opencode")

      for name <- [] do
        assert {:ok, mod} = Runtimes.for_runtime(name)
        assert is_atom(mod)
      end
    end

    test "returns {:error, message} for an unknown runtime" do
      assert {:error, msg} = Runtimes.for_runtime("unknown_runtime")
      assert msg =~ "unsupported runtime"
    end
  end

  describe "dispatching an optional callback on a module that is not loaded" do
    # The point of the dispatchers. `function_exported?/3` answers false for a
    # module that is merely not loaded yet, so the naive guard silently no-ops
    # a callback the runtime does implement — which is how a host lost its
    # whole credential env on a provisioning run that reported every stage
    # green. Merely calling the function loads the module, so each of these
    # depends on the unload in `setup` to mean anything.

    test "default_env/3 still reaches the implementation" do
      env = Runtimes.default_env(@unloaded, %{}, %{anthropic_api_key: "sk-test"})

      assert env == [{"UNLOADED_KEY", "sk-test"}],
             "optional callback silently no-opped on an unloaded module"
    end

    test "write_config/3 still reaches the implementation" do
      assert Runtimes.write_config(@unloaded, :handle, %{}) == {:error, :wrote_config},
             "optional callback silently no-opped on an unloaded module"
    end

    test "prepare_sandbox/4 still reaches the implementation" do
      assert Runtimes.prepare_sandbox(@unloaded, :handle, %{}, []) == {:error, :prepared_sandbox},
             "optional callback silently no-opped on an unloaded module"
    end

    test "implements?/3 answers for the callback with no dispatcher" do
      assert Runtimes.implements?(@unloaded, :build_command, 5),
             "guard answered false for an unloaded module that implements the callback"
    end
  end

  describe "dispatching an optional callback a runtime does not implement" do
    # The matrix is sparse in both directions, so these are the live rows:
    # claude has no prepare_sandbox/3, codex no write_config/2, and nobody
    # implements build_command/5.

    test "prepare_sandbox/4 is :ok" do
      assert Runtimes.prepare_sandbox(Managoat.Runtimes.Claude, :handle, %{}, []) == :ok
    end

    test "write_config/3 is :ok" do
      assert Runtimes.write_config(Managoat.Runtimes.Codex, :handle, %{}) == :ok
    end

    test "model_env/2 is []" do
      assert Runtimes.model_env(Managoat.Runtimes.Codex, "gpt-5") == []
    end

    test "default_env/3 is []" do
      # No runtime is missing default_env/2; a module that is not a runtime at
      # all stands in for the fifth one that will be.
      assert Runtimes.default_env(Managoat.Runtimes.Layout, %{}, %{anthropic_api_key: "k"}) == []
    end

    test "implements?/3 is false, including for a module that does not exist" do
      refute Runtimes.implements?(Managoat.Runtimes.Claude, :build_command, 5)
      refute Runtimes.implements?(Managoat.Runtimes.NoSuchRuntime, :default_env, 2)
    end
  end

  describe "dispatching to a runtime that implements the callback" do
    test "returns what the callback returns" do
      assert Runtimes.default_env(Managoat.Runtimes.Claude, %{}, %{anthropic_api_key: "sk-x"}) ==
               [{"ANTHROPIC_API_KEY", "sk-x"}, {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}]

      assert Runtimes.model_env(Managoat.Runtimes.Claude, "claude-opus-5") ==
               [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]
    end
  end
end
