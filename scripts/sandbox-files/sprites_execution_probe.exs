# Opt-in LIVE characterization. Creates and deletes one disposable Sprite.
# SPRITES_TOKEN must already be in the environment; never print the credential.
# Run: MIX_ENV=test mise exec -- mix run --no-start scripts/sandbox-files/sprites_execution_probe.exs
unless Mix.env() == :test, do: raise("run with MIX_ENV=test")

Logger.configure(level: :emergency)
{:ok, _} = Application.ensure_all_started(:sprites)

defmodule Fountain.SpritesExecutionProbe do
  alias Managoat.Sandbox.Sprites, as: Adapter

  def run do
    token = System.fetch_env!("SPRITES_TOKEN")

    Application.put_env(:managoat_sandbox, Adapter,
      token: token,
      timeout_ms: 15_000,
      public_urls: false
    )

    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    name = "fountain-2394-probe-#{suffix}"

    req =
      Req.new(
        base_url: "https://api.sprites.dev",
        headers: [{"authorization", "Bearer " <> token}],
        retry: false,
        redirect: false,
        receive_timeout: 30_000,
        connect_options: [timeout: 5_000]
      )

    # A private recovery record contains only this newly generated name and ID.
    # It is written before submission, so a lost create response remains visible.
    record = Path.join(System.tmp_dir!(), name <> ".json")
    File.write!(record, Jason.encode!(%{name: name, status: "create_pending"}), [:exclusive])
    File.chmod!(record, 0o600)
    emit(%{event: "create_pending", name: name, recovery_record: record})

    case Req.post(req, url: "/v1/sprites", json: %{name: name}) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 ->
        File.write!(record, Jason.encode!(%{name: name, id: id, status: "created"}))
        emit(%{event: "created", name: name, id: id})

        try do
          probe(Adapter.build_handle(name))
        after
          cleanup(req, name, id, record)
        end

      _ ->
        # Never adopt or delete a resource after a conflict or uncertain create.
        raise "create not confirmed; reconcile the recovery record"
    end
  end

  defp probe(handle) do
    {:ok, versions, 0} = exec(handle, "import platform; print(platform.platform())", 5_000)
    emit(%{event: "guest", platform: String.trim(versions)})

    for stream <- ["stdout", "stderr"] do
      code =
        "import sys,time\nfor _ in range(20):\n print('x',file=sys.#{stream},flush=True); time.sleep(0.1)"

      {elapsed, result} = timed(fn -> exec(handle, code, 500) end)

      emit(%{
        event: "continuous_output",
        stream: stream,
        supplied_timeout_ms: 500,
        elapsed_ms: elapsed,
        result: outcome(result)
      })
    end

    for resistant <- [false, true], do: descendant(handle, resistant)
  end

  defp descendant(handle, resistant) do
    label = if resistant, do: "ignore-term", else: "normal"
    marker = "/tmp/fountain2394-#{label}"

    child = """
    import os,signal,time
    #{if resistant, do: "signal.signal(signal.SIGTERM, signal.SIG_IGN)", else: "pass"}
    with open(#{inspect(marker)}, 'w', buffering=1) as f:
      for _ in range(150):
        f.write(str(os.getpid())+'\\n'); time.sleep(0.1)
    """

    parent = """
    import subprocess,sys
    p=subprocess.Popen([sys.executable,'-c',#{inspect(child)}],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print('READY',flush=True)
    p.wait(timeout=18)
    """

    {elapsed, result} = timed(fn -> exec(handle, parent, 500) end)
    emit(%{event: "silent_timeout", case: label, elapsed_ms: elapsed, result: outcome(result)})
    {:error, {:unavailable, {:exec_timeout, 500}}} = result

    {:ok, sessions} = bounded(fn -> Adapter.list_sessions(handle) end)
    [session] = Enum.filter(sessions, &String.contains?(&1.command || "", marker))

    before = ticks(handle, marker)
    Process.sleep(400)
    after_timeout = ticks(handle, marker)

    emit(%{
      event: "after_local_timeout",
      case: label,
      session_id: session.id,
      heartbeat_before: before,
      heartbeat_after: after_timeout,
      child_still_writing: after_timeout > before
    })

    {kill_elapsed, kill_result} =
      timed(fn ->
        bounded(fn -> Adapter.terminate_session(handle, session.id, timeout_ms: 500) end)
      end)

    stopped_before = ticks(handle, marker)
    Process.sleep(500)
    stopped_after = ticks(handle, marker)

    emit(%{
      event: "after_explicit_termination",
      case: label,
      elapsed_ms: kill_elapsed,
      result: outcome(kill_result),
      heartbeat_before: stopped_before,
      heartbeat_after: stopped_after,
      child_still_writing: stopped_after > stopped_before
    })
  end

  defp ticks(handle, marker) do
    {:ok, count, 0} = exec(handle, "print(len(open(#{inspect(marker)}).readlines()))", 5_000)
    count |> String.trim() |> String.to_integer()
  end

  defp exec(handle, code, timeout) do
    bounded(fn -> Adapter.exec(handle, "python3", ["-c", code], timeout: timeout) end)
  end

  defp bounded(fun) do
    task =
      Task.async(fn ->
        try do
          {:probe_result, fun.()}
        rescue
          _ -> :probe_exception
        catch
          _, _ -> :probe_exception
        end
      end)

    case Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:probe_result, result}} -> result
      _ -> raise "local probe guard expired; remote state is uncertain"
    end
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # Deliberately omit provider prose, command handles and transport errors.
  defp outcome(:ok), do: "ok"
  defp outcome({:ok, _, code}) when is_integer(code), do: "exit_#{code}"
  defp outcome({:error, {:unavailable, {:exec_timeout, _}}}), do: "local_exec_timeout"
  defp outcome({:error, _}), do: "error"

  defp cleanup(req, name, id, record) do
    # Refuse cleanup if the generated name resolves to a different incarnation.
    {:ok, %{status: 200, body: %{"id" => ^id}}} = Req.get(req, url: "/v1/sprites/#{name}")
    {:ok, %{status: status}} = Req.delete(req, url: "/v1/sprites/#{name}")
    true = status in 200..299
    {:ok, %{status: 404}} = Req.get(req, url: "/v1/sprites/#{name}")
    File.write!(record, Jason.encode!(%{name: name, id: id, status: "deleted_verified"}))
    emit(%{event: "deleted_verified", name: name})
  end

  defp emit(event), do: IO.puts("EVIDENCE " <> Jason.encode!(event))
end

try do
  Fountain.SpritesExecutionProbe.run()
rescue
  error ->
    # Exception contents can contain request headers; report only the type.
    IO.puts("PROBE FAILED (#{inspect(error.__struct__)}); check recovery record and cleanup")
    System.halt(1)
end
