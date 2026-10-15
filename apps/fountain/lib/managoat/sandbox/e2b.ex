defmodule Managoat.Sandbox.E2B do
  @moduledoc """
  The E2B adapter: `Managoat.Sandbox` implemented against e2b.dev.

  ## Identity

  E2B assigns sandbox ids; Fountain's name-keyed identity is emulated by
  stamping the minted name into sandbox `metadata` and resolving by a
  server-side metadata filter on every operation. `create/2` adopts an
  existing sandbox with the same name, and the reaper converges the
  duplicate a create/create race can leave behind.

  ## Suspend

  Advertises `:suspend` with real calls behind it: `suspend/1` is an
  explicit pause (filesystem + memory snapshot, retained indefinitely at
  storage-only cost) and `resume/1` is the `/connect` call that restores
  it. Every running E2B sandbox carries a TTL, so live commands heartbeat
  it (`Managoat.Sandbox.E2B.CommandServer`); sandboxes are created with
  `autoPause: true` so a missed heartbeat degrades to a pause, never a
  kill. Operations that find the sandbox paused resume it first — an
  auto-paused sandbox under a `ready` row self-heals on the next use.

  ## Streaming and reattach

  Commands run through envd's Connect-RPC `process.Process` service
  (`Managoat.Sandbox.E2B.Envd`). envd does **not** replay a reconnected
  process's output — `Connect` tails from now, and detached output is
  discarded — so detachable spawns run under a journaling shim: stdout and
  stderr `tee` into `/tmp/fountain/<tag>.{out,err}` and the exit code lands
  in `<tag>.exit`. `attach/3` then satisfies the replay-from-start contract
  exactly by spawning a `tail -c +1 -f` replayer over the journals (byte
  zero onward, then live) that ends when the exit file appears; the real
  exit code is read from the file. stdin still addresses the original
  process by tag.

  ## Template

  Sandboxes are created from `E2B_TEMPLATE`, which must carry the agent
  CLIs and the `sprite` user layout the provisioning pipeline assumes —
  see `images/e2b/` for the reference Dockerfile.
  """

  @behaviour Managoat.Sandbox

  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.E2B.Api
  alias Managoat.Sandbox.E2B.CommandServer
  alias Managoat.Sandbox.E2B.Envd
  alias Managoat.Sandbox.E2B.Errors
  alias Managoat.Sandbox.ExecDeadline
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy
  alias Managoat.Sandbox.Session

  @journal_dir "/tmp/fountain"

  @impl true
  def provider, do: :e2b

  @impl true
  def capabilities, do: MapSet.new([:suspend, :network_policy, :attach])

  @impl true
  def build_handle(name) when is_binary(name), do: %Handle{provider: :e2b, name: name}

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @impl true
  def create(name, _opts) when is_binary(name) do
    case Api.find_by_name(name) do
      {:ok, nil} ->
        case Api.create_sandbox(name) do
          {:ok, info} -> {:ok, %Handle{provider: :e2b, name: name, private: sandbox_id(info)}}
          {:error, reason} -> {:error, Errors.normalize(reason)}
        end

      # Adopt: the name already exists (an earlier attempt won the race or
      # lost its response).
      {:ok, info} ->
        {:ok, %Handle{provider: :e2b, name: name, private: sandbox_id(info)}}

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  # E2B exposes per-port hostnames rather than one sandbox URL, and nothing here
  # asks it to open a port yet. Reporting a guess would send someone to an
  # address that does not answer, which is worse than reporting nothing.
  def public_url(%Handle{}), do: {:error, :unsupported}

  @impl true
  def get(%Handle{name: name}) do
    case Api.find_by_name(name) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, info} -> {:ok, %{status: normalize_state(info), raw: info}}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def destroy(%Handle{name: name}) do
    case Api.find_by_name(name) do
      {:ok, nil} -> :ok
      {:ok, info} -> info |> sandbox_id() |> Api.delete_sandbox() |> normalize_ok()
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def list_all_names do
    case Api.list_all_names() do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def suspend(%Handle{name: name}) do
    case Api.find_by_name(name) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %{"state" => "paused"}} -> :ok
      {:ok, info} -> info |> sandbox_id() |> Api.pause() |> normalize_ok()
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def resume(%Handle{name: name} = handle) do
    with {:ok, id} <- resolve_running(name) do
      {:ok, %{handle | private: id}}
    end
  end

  # ── filesystem ─────────────────────────────────────────────────────────────

  @impl true
  def write_file(%Handle{} = handle, path, data, _opts) do
    with {:ok, id} <- resolve_running(handle.name) do
      Envd.write_file(id, path, data) |> normalize_ok()
    end
  end

  # ── exec ───────────────────────────────────────────────────────────────────

  @impl true
  def exec(%Handle{} = handle, cmd, args, opts) do
    deadline = ExecDeadline.new(Keyword.get(opts, :timeout, :infinity))
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)

    with :ok <- ExecDeadline.check(deadline),
         {:ok, id} <- resolve_running(handle.name),
         :ok <- ExecDeadline.check(deadline) do
      ref = make_ref()
      request = {"process.Process/Start", Envd.start_request(new_tag(), cmd, args, opts)}

      case CommandServer.start(
             sandbox_id: id,
             tag: "exec",
             ref: ref,
             owner: self(),
             request: request
           ) do
        {:ok, pid} -> collect(pid, ref, [], stderr_to_stdout, deadline)
        {:error, reason} -> {:error, Errors.normalize(reason)}
      end
    end
  end

  # Check before every receive, including when frames are already queued.
  # Local collector shutdown is not confirmation that the remote process ended.
  defp collect(pid, ref, acc, stderr_to_stdout, deadline) do
    case ExecDeadline.remaining(deadline) do
      0 -> expire(pid, deadline)
      remaining -> collect_frame(pid, ref, acc, stderr_to_stdout, deadline, remaining)
    end
  end

  defp collect_frame(pid, ref, acc, stderr_to_stdout, deadline, remaining) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        collect(pid, ref, [acc | data], stderr_to_stdout, deadline)

      {:stderr, %{ref: ^ref}, data} when stderr_to_stdout ->
        collect(pid, ref, [acc | data], stderr_to_stdout, deadline)

      {:stderr, %{ref: ^ref}, _data} ->
        collect(pid, ref, acc, stderr_to_stdout, deadline)

      {:exit, %{ref: ^ref}, code} ->
        case ExecDeadline.check(deadline) do
          :ok -> {:ok, IO.iodata_to_binary(acc), code}
          {:error, _} -> expire(pid, deadline)
        end

      {:error, %{ref: ^ref}, reason} ->
        {:error, Errors.normalize(reason)}
    after
      remaining -> expire(pid, deadline)
    end
  end

  defp expire(pid, deadline) do
    Process.exit(pid, :kill)
    ExecDeadline.error(deadline)
  end

  @impl true
  def spawn(%Handle{} = handle, cmd, args, opts) do
    with {:ok, id} <- resolve_running(handle.name) do
      tag = new_tag()
      ref = make_ref()
      owner = Keyword.get(opts, :owner, self())

      request =
        if Keyword.get(opts, :detachable, false) do
          {"process.Process/Start",
           Envd.start_request(tag, "bash", ["-lc", journal_shim(tag, cmd, args)], opts)}
        else
          {"process.Process/Start", Envd.start_request(tag, cmd, args, opts)}
        end

      case CommandServer.start(sandbox_id: id, tag: tag, ref: ref, owner: owner, request: request) do
        {:ok, pid} ->
          started(pid, ref, tag, id)

        {:error, reason} ->
          {:error, Errors.normalize(reason)}
      end
    end
  end

  # Spawn returns only once envd has start-acked the tagged process. The
  # caller's first write_stdin addresses it by tag, and a write that races
  # registration 404s — which reads as "already exited" and killed prod
  # turns at ~300ms (2026-08-14).
  defp started(pid, ref, tag, sandbox_id) do
    case CommandServer.await_start(pid, start_timeout()) do
      :ok ->
        {:ok,
         %Command{
           provider: :e2b,
           ref: ref,
           private: %{pid: pid, tag: tag, sandbox_id: sandbox_id}
         }}

      {:error, reason} ->
        stop_quietly(pid)
        {:error, Errors.normalize(reason)}
    end
  end

  # The server may have stopped on its own between the failed await and
  # this cleanup — racing it is fine, being taken down by it is not.
  defp stop_quietly(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp start_timeout, do: Managoat.Sandbox.Config.get(Managoat.Sandbox.E2B, :timeout_ms, 30_000)

  # stdout/stderr tee into append-only journals and the exit code lands in a
  # sentinel file — the raw material attach/3's replayer needs. `exec`
  # replaces the wrapper shell so stdin reaches the command directly.
  defp journal_shim(tag, cmd, args) do
    quoted = Enum.map_join([cmd | args], " ", &shell_quote/1)
    base = "#{@journal_dir}/#{tag}"

    """
    mkdir -p #{@journal_dir}
    { #{quoted}; echo $? > #{base}.exit; } \
      > >(tee -a #{base}.out) 2> >(tee -a #{base}.err >&2)
    exit $(cat #{base}.exit)
    """
  end

  # The attach replayer: journal bytes from byte zero (stdout on fd1, stderr
  # on fd2 — envd keeps them separate), then follow until the exit sentinel
  # appears. A short grace lets tee flush the final bytes before the tails
  # stop. The replayer's own exit is a proxy; CommandServer reads the real
  # code from the exit file.
  defp replay_script(tag) do
    base = "#{@journal_dir}/#{tag}"

    """
    touch #{base}.out #{base}.err
    tail -c +1 -f #{base}.out & OUT=$!
    tail -c +1 -f #{base}.err >&2 & ERR=$!
    while [ ! -f #{base}.exit ]; do sleep 0.2; done
    sleep 0.5
    kill $OUT $ERR 2>/dev/null
    exit 0
    """
  end

  defp shell_quote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @impl true
  def write_stdin(%Command{provider: :e2b, private: %{pid: pid}}, data) do
    CommandServer.write_stdin(pid, data) |> normalize_ok()
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:normal, :noproc, :shutdown] ->
      {:error, :command_exited}

    :exit, reason ->
      {:error, {:write_failed, reason}}
  end

  @impl true
  def close_stdin(%Command{provider: :e2b, private: %{pid: pid}}) do
    CommandServer.close_stdin(pid) |> normalize_ok()
  catch
    :exit, _ -> :ok
  end

  @impl true
  def stop_command(%Command{provider: :e2b, private: %{pid: pid}}) do
    GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── sessions ───────────────────────────────────────────────────────────────

  @impl true
  def list_sessions(%Handle{} = handle) do
    with {:ok, id} <- resolve_running(handle.name) do
      case Envd.list_processes(id) do
        {:ok, processes} ->
          sessions =
            for %{"tag" => tag} = process <- processes,
                is_binary(tag) and String.starts_with?(tag, "fountain-") do
              %Session{id: tag, command: command_line(process)}
            end

          {:ok, sessions}

        {:error, reason} ->
          {:error, Errors.normalize(reason)}
      end
    end
  end

  @impl true
  def attach(%Handle{} = handle, tag, opts) do
    with {:ok, id} <- resolve_running(handle.name) do
      ref = make_ref()
      owner = Keyword.get(opts, :owner, self())

      request =
        {"process.Process/Start",
         Envd.start_request(new_tag(), "bash", ["-lc", replay_script(tag)], [])}

      case CommandServer.start(
             sandbox_id: id,
             tag: tag,
             ref: ref,
             owner: owner,
             request: request,
             stdin_tag: tag,
             exit_file: "#{@journal_dir}/#{tag}.exit"
           ) do
        {:ok, pid} ->
          started(pid, ref, tag, id)

        {:error, reason} ->
          {:error, Errors.normalize(reason)}
      end
    end
  end

  # ── governance ─────────────────────────────────────────────────────────────

  @impl true
  def apply_network_policy(%Handle{} = handle, %NetworkPolicy{allow: allow}) do
    with {:ok, id} <- resolve_running(handle.name) do
      id |> Envd.id_of() |> Api.set_network(allow) |> normalize_ok()
    end
  end

  @impl true
  def create_checkpoint(%Handle{}, _opts), do: {:error, :not_supported}

  @impl true
  def restore_checkpoint(%Handle{}, _checkpoint_id), do: {:error, :not_supported}

  # ── internals ──────────────────────────────────────────────────────────────

  # Resolve the sandbox to an envd target, resuming a paused sandbox on the
  # way: E2B's TTL auto-pause can park a sandbox under a `ready` row, and
  # self-healing here beats surfacing an unreachable-envd error for a disk
  # that is fine.
  defp resolve_running(name) do
    with {:ok, id} <- resolve_running_id(name), do: {:ok, target(id)}
  end

  # envd's access token comes only with the sandbox's detail (a listing
  # leaves it out). A sandbox created without `secure` has none, and its
  # target is the bare id; so is one whose detail can't be read, whose envd
  # calls then fail on their own terms.
  defp target(id) do
    case Api.get_sandbox(id) do
      {:ok, %{"envdAccessToken" => token}} when is_binary(token) and token != "" ->
        %Envd.Target{id: id, token: token}

      _other ->
        id
    end
  end

  defp resolve_running_id(name) do
    case Api.find_by_name(name) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, %{"state" => "paused"} = info} ->
        id = sandbox_id(info)

        case Api.connect(id) do
          :ok -> {:ok, id}
          {:error, reason} -> {:error, Errors.normalize(reason)}
        end

      {:ok, info} ->
        {:ok, sandbox_id(info)}

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  defp sandbox_id(%{"sandboxID" => id}) when is_binary(id), do: id
  defp sandbox_id(%{"sandboxId" => id}) when is_binary(id), do: id

  defp normalize_state(%{"state" => "paused"}), do: :suspended
  defp normalize_state(%{"state" => "running"}), do: :running
  defp normalize_state(_info), do: :unknown

  defp normalize_ok(:ok), do: :ok
  defp normalize_ok({:ok, _}), do: :ok
  defp normalize_ok({:error, reason}), do: {:error, Errors.normalize(reason)}

  defp command_line(%{"config" => %{"cmd" => cmd, "args" => args}}) when is_list(args),
    do: Enum.join([cmd | args], " ")

  defp command_line(_process), do: nil

  defp new_tag, do: "fountain-#{System.unique_integer([:positive])}"
end
