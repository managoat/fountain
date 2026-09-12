defmodule Fountain.ChatGPTAccounts.RefreshCoordinator do
  @moduledoc """
  Bounded, node-local coalescing of user-grant refresh requests.

  Workers receive only owner/grant/generation IDs and return only status.
  Every caller re-reads its own pinned credential after renewal. No bearer,
  encryption key or provider response is cached in the coordinator.

  Same-generation callers share a worker. Other grants can run concurrently,
  up to the supervisor's bound; excess work receives `:refresh_busy`. Each
  grant has at most 128 waiting callers and every worker has a deadline.
  PostgreSQL exclusion remains the cross-node authority.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def run(grant_id, user_id, generation, server \\ __MODULE__)
      when is_binary(grant_id) and is_binary(user_id) and is_binary(generation) do
    GenServer.call(server, {:refresh, {user_id, grant_id, generation}}, 30_000)
  catch
    :exit, _ -> {:error, :refresh_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       tasks: Keyword.fetch!(opts, :task_supervisor),
       worker: Keyword.get(opts, :worker, Fountain.ChatGPTAccounts),
       max_concurrency: Keyword.get(opts, :max_concurrency, 4),
       max_waiters: Keyword.get(opts, :max_waiters, 128),
       timeout: Keyword.get(opts, :worker_timeout, 27_000),
       jobs: %{},
       callers: %{}
     }}
  end

  @impl true
  def handle_call({:refresh, key}, from, state) do
    case Map.fetch(state.jobs, key) do
      {:ok, job} when map_size(job.waiters) < state.max_waiters ->
        {:noreply, add_waiter(state, key, from)}

      :error when map_size(state.jobs) < state.max_concurrency ->
        start_worker(state, key, from)

      _ ->
        {:reply, {:error, :refresh_busy}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case find_worker(state, ref) do
      {key, _job} -> {:noreply, finish(state, key, safe_result(result))}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case find_worker(state, ref) do
      {key, _job} -> {:noreply, finish(state, key, {:error, :refresh_unavailable})}
      nil -> {:noreply, remove_waiter(state, ref)}
    end
  end

  def handle_info({:refresh_timeout, ref}, state) do
    case find_worker(state, ref) do
      {key, job} ->
        Task.shutdown(job.task, :brutal_kill)
        {:noreply, finish(state, key, {:error, :refresh_timeout})}

      nil ->
        {:noreply, state}
    end
  end

  defp start_worker(state, {user_id, grant_id, generation} = key, from) do
    task =
      Task.Supervisor.async_nolink(state.tasks, state.worker, :refresh_serialized_for_user, [
        grant_id,
        user_id,
        generation
      ])

    timer = Process.send_after(self(), {:refresh_timeout, task.ref}, state.timeout)
    state = put_in(state.jobs[key], %{task: task, timer: timer, waiters: %{}})
    {:noreply, add_waiter(state, key, from)}
  rescue
    # The Task.Supervisor also enforces the cap while a worker is terminating.
    RuntimeError -> {:reply, {:error, :refresh_busy}, state}
  end

  defp add_waiter(state, key, {pid, _tag} = from) do
    ref = Process.monitor(pid)
    state = put_in(state.jobs[key].waiters[ref], from)
    put_in(state.callers[ref], key)
  end

  defp remove_waiter(state, ref) do
    case Map.pop(state.callers, ref) do
      {nil, _} ->
        state

      {key, callers} ->
        # Keep a started exchange alive even if all callers leave: killing it
        # after upstream rotation could lose the only valid refresh token.
        state = update_in(state.jobs[key].waiters, &Map.delete(&1, ref))
        %{state | callers: callers}
    end
  end

  defp finish(state, key, result) do
    {job, jobs} = Map.pop(state.jobs, key)
    Process.cancel_timer(job.timer)
    Process.demonitor(job.task.ref, [:flush])

    for {ref, from} <- job.waiters do
      Process.demonitor(ref, [:flush])
      GenServer.reply(from, result)
    end

    %{state | jobs: jobs, callers: Map.drop(state.callers, Map.keys(job.waiters))}
  end

  defp find_worker(state, ref),
    do: Enum.find(state.jobs, fn {_key, job} -> job.task.ref == ref end)

  defp safe_result(:ok), do: :ok
  defp safe_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp safe_result(_), do: {:error, :refresh_unavailable}
end
