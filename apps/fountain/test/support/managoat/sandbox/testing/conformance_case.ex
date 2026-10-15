defmodule Managoat.Sandbox.ConformanceCase do
  @moduledoc """
  The executable form of the `Managoat.Sandbox` contract: a shared suite
  every adapter must pass.

  Test-only (`test/support`). The fake runs it on every `mix test`
  (`fake_conformance_test.exs`), and the live provider suites
  (`test/live/sandbox_*_live_test.exs`) run it against Sprites and E2B. It
  lived under the hex library's `lib/`, for adapters written outside it,
  until the library was folded back into Fountain (decisions/0037,
  2026-10-15).

  Usage:

      defmodule Managoat.Sandbox.FakeConformanceTest do
        use Managoat.Sandbox.ConformanceCase,
          adapter: Managoat.Sandbox.Fake,
          fixtures: %{
            exec_ok: {"emit", ["out:hello"], "hello"},
            exec_fail: {"emit", ["out:oops", "exit:3"], 3},
            spawn_ok: {"emit", ["out:hello", "exit:0"]},
            spawn_drop: {"emit", ["out:partial", "drop"]},
            spawn_stay: {"emit", ["out:ready", "stay"]}
          }

        setup do
          Managoat.Sandbox.Fake.reset()
          :ok
        end
      end

  `fixtures` supplies the adapter-appropriate command vocabulary (the Fake
  speaks its scripted instructions; a live adapter would use `bash -lc`), and
  an optional `name: {Mod, :fun, args}` mints sandbox names when the adapter
  needs a particular shape:

    * `exec_ok` — `{cmd, args, expected_stdout}`, exits 0
    * `exec_fail` — `{cmd, args, nonzero_exit_code}`
    * `spawn_ok` — emits some stdout then exits 0
    * `spawn_drop` — the transport closes without an exit frame (optional;
      pins the closes-without-exit-is-an-error rule)
    * `spawn_stay` — emits stdout then stays alive until stdin EOF
      (needed for the write-totality and attach-replay tests)

  Three more options exist for adapters that talk to a real provider:

    * `moduletag` — tags every test in the module, conformance tests
      included (a `@moduletag` after the `use` misses them), so a live run
      can be excluded by default

    * `timeout` — how long each `assert_receive` waits for a frame
      (default 1_000 ms, which suits in-process adapters; a network round
      trip needs more)
    * `spawn_opts` — merged into every `spawn/4` call, for an adapter whose
      attach replay depends on how the command was started (E2B journals
      only `detachable: true` spawns)

  Semantics pinned here and nowhere else: create idempotency, the
  not-found/transient distinction, destroy tolerance, full-view listing,
  exec-never-raises with nonzero-exit-as-data, the owner-message frame
  contract with exactly one terminal frame and no synthesised exit code,
  stdin-write totality (#603),
  attach replay-from-start, and suspend/resume totality.
  """

  defmacro __using__(opts) do
    moduletag =
      if tag = opts[:moduletag] do
        quote do: @moduletag(unquote(tag))
      end

    quote do
      use ExUnit.Case, async: false

      # Before any conformance test is defined, so it reaches all of them.
      unquote(moduletag)

      @adapter unquote(opts[:adapter])
      @fixtures unquote(opts[:fixtures])
      @conformance_timeout unquote(Keyword.get(opts, :timeout, 1_000))
      @conformance_spawn_opts unquote(Keyword.get(opts, :spawn_opts, []))

      # Adapters whose names carry routing (the runner adapter's names name
      # the runner) supply `name: {Mod, :fun, args}` to mint routable ones.
      defp conformance_name do
        case unquote(opts[:name]) do
          nil -> "conformance-#{System.unique_integer([:positive])}"
          {mod, fun, args} -> apply(mod, fun, args)
        end
      end

      defp created_handle do
        name = conformance_name()
        {:ok, handle} = @adapter.create(name, [])
        handle
      end

      use Managoat.Sandbox.ConformanceCase.Identity, unquote(opts)
      use Managoat.Sandbox.ConformanceCase.Lifecycle, unquote(opts)
      use Managoat.Sandbox.ConformanceCase.Exec, unquote(opts)
      use Managoat.Sandbox.ConformanceCase.Streaming, unquote(opts)
      use Managoat.Sandbox.ConformanceCase.Governance, unquote(opts)
    end
  end
end

defmodule Managoat.Sandbox.ConformanceCase.Identity do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      describe "#{inspect(adapter)} conformance: identity" do
        test "build_handle/1 is pure and provider-tagged" do
          name = conformance_name()
          handle = @adapter.build_handle(name)
          assert handle.provider == @adapter.provider()
          assert handle.name == name
        end

        test "capabilities/0 is a MapSet of known capabilities" do
          caps = @adapter.capabilities()
          assert %MapSet{} = caps

          known = MapSet.new([:suspend, :network_policy, :attach, :tty, :public_url])

          assert MapSet.subset?(caps, known)
        end

        # The capability is a promise about the answer, not just about the
        # function existing: an adapter that advertises :public_url must return
        # a URL, and one that does not must say :unsupported rather than
        # inventing an address a human would then be sent to.
        test "public_url/1 agrees with the advertised capability" do
          {:ok, handle} = @adapter.create(conformance_name(), [])
          on_exit(fn -> @adapter.destroy(handle) end)

          # Through apply/3: the clauses below cover every adapter, and the
          # type checker would otherwise warn that one adapter's (the fake's)
          # answer never reaches a clause another adapter's does.
          case apply(@adapter, :public_url, [handle]) do
            {:ok, url} ->
              assert MapSet.member?(@adapter.capabilities(), :public_url),
                     "returned a URL without advertising :public_url"

              assert String.starts_with?(url, "http"),
                     "public_url must be openable, got: #{inspect(url)}"

            {:error, :unsupported} ->
              refute MapSet.member?(@adapter.capabilities(), :public_url),
                     "advertises :public_url but answers :unsupported"

            {:error, _other} ->
              # A provider that is reachable but has no sandbox by that name is
              # allowed to fail; the capability claim is what is under test.
              :ok
          end
        end
      end
    end
  end
end

defmodule Managoat.Sandbox.ConformanceCase.Lifecycle do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      describe "#{inspect(adapter)} conformance: lifecycle" do
        test "create is name-keyed and idempotent-adopting" do
          name = conformance_name()
          assert {:ok, first} = @adapter.create(name, [])
          assert {:ok, second} = @adapter.create(name, [])
          assert first.name == second.name
          assert {:ok, %{status: _}} = @adapter.get(first)
        end

        test "get on a nonexistent sandbox is exactly {:error, :not_found}" do
          assert {:error, :not_found} = @adapter.get(@adapter.build_handle(conformance_name()))
        end

        test "destroy tolerates an already-gone sandbox and is definitive" do
          assert :ok = @adapter.destroy(@adapter.build_handle(conformance_name()))

          handle = created_handle()
          assert :ok = @adapter.destroy(handle)
          assert {:error, :not_found} = @adapter.get(handle)
        end

        test "list_all_names returns the full account view as a MapSet" do
          handle = created_handle()
          assert {:ok, %MapSet{} = names} = @adapter.list_all_names()
          assert MapSet.member?(names, handle.name)
        end

        test "suspend and resume are total; resume returns a usable handle" do
          handle = created_handle()
          assert :ok = @adapter.suspend(handle)
          assert {:ok, resumed} = @adapter.resume(handle)
          assert {:ok, %{status: _}} = @adapter.get(resumed)
        end
      end
    end
  end
end

defmodule Managoat.Sandbox.ConformanceCase.Exec do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      describe "#{inspect(adapter)} conformance: exec" do
        test "collects output; zero exit" do
          {cmd, args, expected} = @fixtures.exec_ok
          assert {:ok, out, 0} = @adapter.exec(created_handle(), cmd, args, [])
          assert out =~ expected
        end

        test "with an :on_output sink, chunks and the returned output are the whole output" do
          {cmd, args, expected} = @fixtures.exec_ok
          test_pid = self()
          sink = fn chunk -> send(test_pid, {:chunk, chunk}) end

          assert {:ok, out, 0} =
                   @adapter.exec(created_handle(), cmd, args, on_output: sink)

          assert collected_chunks() <> out =~ expected
        end

        test "a nonzero exit is data, not an error — and never a raise" do
          {cmd, args, code} = @fixtures.exec_fail
          assert {:ok, _out, ^code} = @adapter.exec(created_handle(), cmd, args, [])
        end
      end

      defp collected_chunks(acc \\ "") do
        receive do
          {:chunk, chunk} -> collected_chunks(acc <> chunk)
        after
          0 -> acc
        end
      end
    end
  end
end

defmodule Managoat.Sandbox.ConformanceCase.Streaming do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter], fixtures: opts[:fixtures]] do
      describe "#{inspect(adapter)} conformance: streaming commands" do
        test "frames carry the command ref; output precedes exactly one terminal frame" do
          {cmd, args} = @fixtures.spawn_ok
          handle = created_handle()

          assert {:ok, command} =
                   @adapter.spawn(
                     handle,
                     cmd,
                     args,
                     Keyword.merge(@conformance_spawn_opts, owner: self(), stdin: false)
                   )

          ref = command.ref

          assert_receive {:stdout, %{ref: ^ref}, data}, @conformance_timeout
          assert is_binary(data)
          assert_receive {:exit, %{ref: ^ref}, 0}, @conformance_timeout
          refute_receive {:exit, %{ref: ^ref}, _}, 50
        end

        if fixtures[:spawn_drop] do
          test "a stream that closes without an exit frame surfaces as an error" do
            {cmd, args} = @fixtures.spawn_drop
            handle = created_handle()

            assert {:ok, command} =
                     @adapter.spawn(
                       handle,
                       cmd,
                       args,
                       Keyword.merge(@conformance_spawn_opts, owner: self(), stdin: false)
                     )

            ref = command.ref

            assert_receive {:stdout, %{ref: ^ref}, _}, @conformance_timeout
            assert_receive {:error, %{ref: ^ref}, _reason}, @conformance_timeout

            # The point of the rule: an unknown fate must not arrive as a
            # clean exit. A synthesised zero is what made every failed setup
            # script in #880 read as a successful one.
            refute_receive {:exit, %{ref: ^ref}, _}, 50
          end
        end

        test "write_stdin is total: an exited command yields :command_exited (#603)" do
          {cmd, args} = @fixtures.spawn_ok
          handle = created_handle()

          assert {:ok, command} =
                   @adapter.spawn(
                     handle,
                     cmd,
                     args,
                     Keyword.merge(@conformance_spawn_opts, owner: self(), stdin: true)
                   )

          ref = command.ref
          assert_receive {:exit, %{ref: ^ref}, 0}, @conformance_timeout

          # The command is gone; the write must come back as an error, not
          # take this process down.
          assert {:error, :command_exited} = @adapter.write_stdin(command, "late\n")
        end

        test "stdin round-trips into a live command; EOF ends it" do
          {cmd, args} = @fixtures.spawn_stay
          handle = created_handle()

          assert {:ok, command} =
                   @adapter.spawn(
                     handle,
                     cmd,
                     args,
                     Keyword.merge(@conformance_spawn_opts, owner: self(), stdin: true)
                   )

          ref = command.ref
          assert_receive {:stdout, %{ref: ^ref}, _ready}, @conformance_timeout

          assert :ok = @adapter.write_stdin(command, "ping")
          assert_receive {:stdout, %{ref: ^ref}, echoed}, @conformance_timeout
          assert echoed =~ "ping"

          assert :ok = @adapter.close_stdin(command)
          assert_receive {:exit, %{ref: ^ref}, 0}, @conformance_timeout
        end

        test "stop_command is total and tears down the local end" do
          {cmd, args} = @fixtures.spawn_stay
          handle = created_handle()

          assert {:ok, command} =
                   @adapter.spawn(
                     handle,
                     cmd,
                     args,
                     Keyword.merge(@conformance_spawn_opts, owner: self(), stdin: true)
                   )

          assert :ok = @adapter.stop_command(command)
          # A second stop of an already-stopped command must still be :ok.
          assert :ok = @adapter.stop_command(command)
        end
      end
    end
  end
end

defmodule Managoat.Sandbox.ConformanceCase.Governance do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      if MapSet.member?(adapter.capabilities(), :attach) do
        describe "#{inspect(adapter)} conformance: detachable sessions" do
          test "attach replays buffered output from the start, then tails" do
            {cmd, args} = @fixtures.spawn_stay
            handle = created_handle()

            assert {:ok, command} =
                     @adapter.spawn(
                       handle,
                       cmd,
                       args,
                       Keyword.merge(@conformance_spawn_opts, owner: self(), stdin: true)
                     )

            first_ref = command.ref
            assert_receive {:stdout, %{ref: ^first_ref}, pre_attach}, @conformance_timeout

            assert {:ok, [session | _]} = @adapter.list_sessions(handle)

            # A different owner attaches: it must see the pre-attach output
            # replayed from byte zero — the caller's byte-skip arithmetic
            # depends on it — and then live frames.
            test_pid = self()

            attacher =
              spawn(fn ->
                {:ok, attached} = @adapter.attach(handle, session.id, owner: self(), stdin: true)
                ref = attached.ref

                receive do
                  {:stdout, %{ref: ^ref}, replayed} -> send(test_pid, {:replayed, replayed})
                end

                receive do
                  {:stdout, %{ref: ^ref}, live} -> send(test_pid, {:tailed, live})
                end
              end)

            assert_receive {:replayed, replayed}, @conformance_timeout
            assert replayed == pre_attach

            # New output reaches both the original owner and the attacher.
            assert :ok = @adapter.write_stdin(command, "after-attach")
            assert_receive {:stdout, %{ref: ^first_ref}, _}, @conformance_timeout
            assert_receive {:tailed, tailed}, @conformance_timeout
            assert tailed =~ "after-attach"

            ref = Process.monitor(attacher)
            assert_receive {:DOWN, ^ref, :process, _, _}, @conformance_timeout
          end
        end
      end

      if MapSet.member?(adapter.capabilities(), :network_policy) do
        describe "#{inspect(adapter)} conformance: network policy" do
          test "an empty allowlist is accepted — deny-all, never a silent no-op" do
            handle = created_handle()

            assert :ok =
                     @adapter.apply_network_policy(handle, %Managoat.Sandbox.NetworkPolicy{
                       allow: []
                     })

            assert :ok =
                     @adapter.apply_network_policy(handle, %Managoat.Sandbox.NetworkPolicy{
                       allow: ["api.example.com"]
                     })
          end
        end
      end
    end
  end
end
