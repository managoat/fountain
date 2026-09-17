defmodule Fountain.Analytics.Sink do
  @moduledoc """
  The one process that talks to PostHog's ingestion endpoint.

  Everything `Fountain.Analytics.capture/4` produces arrives here as a cast
  and leaves in a `POST /batch/`. Batching is not an optimisation here, it is
  the safety property: a per-event request would put a network round trip on
  the audit path, the metering path and every stage transition of every
  conversation.

  ## The rules this process keeps

    * **A caller never waits.** `enqueue/1` is a cast, and a cast to a name
      that is not registered is a no-op, so code paths that run without the
      supervision tree (release tasks, a bare unit test) are unaffected.
    * **The process never waits either.** The HTTP call runs in a monitored
      task, not in `handle_info/2`. A sink that posts inline cannot buffer —
      it is either idle or blocked — so an ingestion stall would back up in
      the mailbox, which has no ceiling, instead of in the queue, which does.
    * **The queue is bounded.** Past 5,000 queued events the oldest half is
      dropped and counted. An analytics backlog must not be the thing that
      runs a node out of memory during an ingestion outage.
    * **A failed flush is dropped, not retried.** PostHog's own SDKs drop on
      failure too; the alternative is a growing queue of stale events plus a
      retry storm aimed at a service that is already unhealthy. Every drop is
      logged and counted in `[:fountain, :analytics, :dropped]`, so "we are
      sending nothing" and "nothing is happening" stay distinguishable — the
      same distinction `record_usage/5`'s counter exists to make.

  ## Delivery mode

  `config :fountain, :analytics_mode, :inline` sends each event from the
  calling process instead of batching. The test suite runs this way so a
  `Req.Test` stub is owned by the process that asserts on it, exactly as
  `Fountain.FeatureFlags` is stubbed; nothing else should use it.
  """

  use GenServer

  require Logger

  @flush_ms 5_000
  @max_batch 100
  @max_queue 5_000
  @timeout_ms 5_000

  ## Client

  @doc "Queue one PostHog payload. Never blocks, never raises."
  @spec enqueue(map()) :: :ok
  def enqueue(payload) do
    case mode() do
      :inline -> post([payload])
      _ -> GenServer.cast(__MODULE__, {:enqueue, payload})
    end

    :ok
  catch
    # A cast cannot fail, but `post/1` in inline mode can be handed a broken
    # payload; analytics must not become the reason a mutation raises.
    kind, reason ->
      Logger.warning("analytics: enqueue failed: #{inspect(kind)} #{inspect(reason)}")
      :ok
  end

  @doc """
  Send what is queued and wait for the request to finish.

  For shutdown and for tests. Ordinary callers use `enqueue/1` and never wait.
  """
  @spec flush(timeout()) :: :ok
  def flush(timeout \\ @timeout_ms * 2) do
    GenServer.call(__MODULE__, :flush, timeout)
  catch
    :exit, _ -> :ok
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  ## Server

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)

    # The instance group is set from here rather than from `Application.start/2`
    # so it happens once per node, after config is loaded, and never in a test
    # that starts the module directly without meaning to reach the network.
    if mode() != :inline, do: send(self(), :identify_instance)

    schedule()

    {:ok, %{queue: [], size: 0, flushing: nil, dropped: 0}}
  end

  @impl true
  def handle_cast({:enqueue, payload}, state) do
    state = %{state | queue: [payload | state.queue], size: state.size + 1}

    {:noreply, state |> trim_if_full() |> flush_if_full()}
  end

  # Defining the clause above removed the `handle_cast/2` that `use GenServer`
  # supplies, which stops the process with `{:bad_cast, message}`; without this
  # one an unknown cast raises instead. Both take the queue with them, and a
  # sink that dies drops every event buffered on this node — analytics is
  # exactly the subsystem that should never cost anything else (#2380).
  #
  # The tag and the arity, never the payload: an `{:enqueue, payload}` that
  # reached here carries a captured event's properties.
  def handle_cast(message, state) do
    Logger.warning("analytics: no handle_cast clause for #{shape(message)}; ignoring")

    {:noreply, state}
  end

  defp shape(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "#{inspect(elem(message, 0))}/#{tuple_size(message)}"

  defp shape(message) when is_atom(message), do: inspect(message)
  defp shape(_message), do: "an unrecognized term"

  @impl true
  def handle_call(:flush, _from, state) do
    # Synchronous by request: drain everything queued, in batches, with no
    # task in between. Only shutdown and tests take this path.
    {:reply, :ok, drain(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule()
    {:noreply, start_flush(state)}
  end

  def handle_info(:identify_instance, state) do
    Fountain.Analytics.identify_instance()
    {:noreply, state}
  end

  # The flush task finished (or died — a crashed task is a dropped batch, which
  # is the same outcome a failed request has, and the task already logged it).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{flushing: ref} = state) do
    {:noreply, %{state | flushing: nil} |> flush_if_full()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    drain(state)
    :ok
  end

  ## Internals

  defp schedule, do: Process.send_after(self(), :flush, @flush_ms)

  defp flush_if_full(%{size: size} = state) when size >= @max_batch, do: start_flush(state)
  defp flush_if_full(state), do: state

  # One flush in flight at a time. Firing a second task while the first is
  # still going would reorder batches and multiply load on an endpoint that is
  # already slow enough to have left a batch in flight.
  defp start_flush(%{flushing: ref} = state) when is_reference(ref), do: state
  defp start_flush(%{size: 0} = state), do: state

  defp start_flush(state) do
    {batch, rest, kept} = take_batch(state)

    task = Task.async(fn -> post(batch) end)

    %{state | queue: rest, size: kept, flushing: task.ref}
  end

  # The queue is built head-first; PostHog reads a batch in order, and
  # out-of-order timestamps are visible in the UI, so the oldest events go out
  # first and any remainder stays newest-first for the next batch.
  defp take_batch(state) do
    ordered = Enum.reverse(state.queue)
    {batch, rest} = Enum.split(ordered, @max_batch)
    {batch, Enum.reverse(rest), length(rest)}
  end

  defp drain(%{size: 0} = state), do: state

  defp drain(state) do
    {batch, rest, kept} = take_batch(state)
    post(batch)
    drain(%{state | queue: rest, size: kept})
  end

  # Drop the oldest half rather than the oldest one: trimming per-event at the
  # ceiling turns a sustained overrun into a per-event traversal, and the
  # events worth keeping during an outage are the recent ones.
  defp trim_if_full(%{size: size} = state) when size <= @max_queue, do: state

  defp trim_if_full(state) do
    keep = div(@max_queue, 2)
    dropped = state.size - keep

    Logger.warning("analytics: queue full, dropped #{dropped} events")

    :telemetry.execute(
      [:fountain, :analytics, :dropped],
      %{count: dropped},
      %{reason: "queue_full"}
    )

    %{state | queue: Enum.take(state.queue, keep), size: keep, dropped: state.dropped + dropped}
  end

  defp post([]), do: :ok

  defp post(batch) do
    req =
      Req.new(
        [
          base_url: host(),
          receive_timeout: @timeout_ms,
          connect_options: [timeout: @timeout_ms],
          retry: false
        ] ++ Application.get_env(:fountain, :analytics_req_options, [])
      )

    body = %{api_key: api_key(), historical_migration: false, batch: batch}

    case Req.post(req, url: "/batch/", json: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        dropped(length(batch), "status_#{status}")

      {:error, reason} ->
        dropped(length(batch), inspect(reason))
    end
  rescue
    e -> dropped(length(batch), Exception.message(e))
  end

  defp dropped(count, reason) do
    Logger.warning("analytics: dropped #{count} events (#{reason})")
    :telemetry.execute([:fountain, :analytics, :dropped], %{count: count}, %{reason: reason})
    :ok
  end

  defp mode, do: Application.get_env(:fountain, :analytics_mode, :async)
  defp api_key, do: Application.get_env(:fountain, :posthog_project_api_key)
  defp host, do: Application.get_env(:fountain, :posthog_host, "https://us.i.posthog.com")
end
