defmodule Fountain.Broker.Native.RequestLog do
  @moduledoc """
  The native broker's egress request log (ADR 0019 gate 4, #1486): a buffered
  writer in front of `broker_requests`, and the query the `/egress` endpoint
  reads back.

  ## Why a buffer

  The proxy emits `[:managoat, :broker, :request]` from the connection
  process that is relaying a sandbox's bytes. Two things follow. A synchronous
  insert there puts the database on the hot path of every proxied request,
  and a raising telemetry handler is *detached* by `:telemetry` — the log
  would stop for the life of the node and nothing would fail (#1427). So
  `record/1` is a `cast` into this process, which batches rows and writes
  them with one `insert_all`, and every write is guarded.

  A chatty conversation makes a lot of rows. The buffer flushes on whichever
  comes first, 200 rows or two seconds, and refuses to grow past 5,000: past
  that, rows are dropped and counted rather than held, so a runaway
  conversation costs a gap in one tenant's log instead of the node's memory.
  `fountain.broker.request_log.dropped` is the series that says so.

  ## What is stored

  Method, host, a redacted path, outcome, the rule that matched and the names of the
  environment variables whose values were attached, plus how the request
  ended: the upstream status, the total duration and the terminal error
  where forwarding did not finish. Never a header, a body or a credential.

  The proxy's event is terminal (`managoat_broker` 0.3.0), so a row appears
  when the response ends rather than when the request is sent. A `git clone`
  or an SSE stream is one row written at the end, carrying the whole
  duration.
  """

  use GenServer

  import Ecto.Query

  alias Fountain.Broker.Native.Request
  alias Fountain.Repo

  require Logger

  @batch 200
  @flush_ms 2_000
  @max_buffered 5_000

  # ---------------------------------------------------------------------------
  # Writing

  @doc "Start the writer. `Fountain.Application` does this on the native backend only."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Buffer one proxied request. Asynchronous and never raises: the caller is
  the proxy relaying a sandbox's bytes, and a telemetry handler that raises
  is detached for the life of the node.
  """
  @spec record(map(), GenServer.server()) :: :ok
  def record(row, server \\ __MODULE__) when is_map(row) do
    GenServer.cast(server, {:record, Map.put(row, :path, redacted_path())})
  catch
    # No writer on this node (brokerage off, or a boot race). Losing the row
    # is the correct outcome; losing the request is not.
    kind, reason ->
      Logger.debug("broker request log: dropped a row: #{inspect({kind, reason})}")
      :ok
  end

  @doc false
  def redacted_path, do: "/[REDACTED]"

  @doc "Write anything buffered, now. Synchronous, so a test can assert on rows."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  # ---------------------------------------------------------------------------
  # Reading

  @doc """
  One page of a conversation's log, newest first. `:limit` caps the page and
  `:before` is the id from a previous page's `next`, so paging walks
  backwards through the ids the way the Agent Vault cursor did.

  `next` is the oldest id on a full page and `nil` on the last one.
  """
  @spec page(String.t(), keyword()) ::
          {:ok, %{events: [Fountain.Broker.egress_event()], next: integer() | nil}}
  def page(conversation_id, opts \\ []) when is_binary(conversation_id) do
    limit = Keyword.get(opts, :limit, 100)

    query =
      from(r in Request,
        where: r.conversation_id == ^conversation_id,
        order_by: [desc: r.id],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :before) do
        nil -> query
        before -> from(r in query, where: r.id < ^before)
      end

    rows = Repo.all(query)

    next = if length(rows) == limit, do: rows |> List.last() |> Map.fetch!(:id)

    {:ok, %{events: Enum.map(rows, &event/1), next: next}}
  end

  @doc "Delete rows older than the cutoff. Returns how many."
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(%DateTime{} = cutoff) do
    {n, _} = Repo.delete_all(from(r in Request, where: r.inserted_at < ^cutoff))
    n
  end

  defp event(%Request{} = r) do
    %{
      id: r.id,
      at: r.inserted_at,
      method: r.method,
      host: r.host,
      # Existing rows may predate write-time redaction; do not expose their
      # paths while the normal retention sweep ages them out.
      path: redacted_path(),
      service: r.service,
      credential_keys: r.credential_keys || [],
      status: r.status,
      latency_ms: r.latency_ms,
      error: r.error
    }
  end

  # ---------------------------------------------------------------------------
  # The server

  @impl GenServer
  def init(_opts), do: {:ok, %{buffer: [], size: 0, timer: nil}}

  @impl GenServer
  def handle_cast({:record, _row}, %{size: size} = state) when size >= @max_buffered do
    :telemetry.execute([:fountain, :broker, :request_log_dropped], %{count: 1}, %{})
    {:noreply, state}
  end

  def handle_cast({:record, row}, state) do
    state = %{state | buffer: [row | state.buffer], size: state.size + 1}

    if state.size >= @batch do
      {:noreply, write(state)}
    else
      {:noreply, arm(state)}
    end
  end

  # Defining the clauses above removed the `handle_cast/2` that `use GenServer`
  # supplies, which stops the process with `{:bad_cast, message}`; without this
  # one an unknown cast raises instead. Either way the buffer goes with it, and
  # a lost buffer is a gap in the egress log for every tenant proxying through
  # this node — so neither is the right answer for a message this writer was
  # never going to store (#2380).
  def handle_cast(message, state) do
    Logger.warning("broker request log: no handle_cast clause for #{shape(message)}; ignoring")

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, write(state)}

  # Same hole on the info side, reached by more: this process is cast to from
  # the proxy's connection processes, so a monitor it never asked for or an
  # `:EXIT` from a linked process arrives here. The buffered rows are worth
  # more than the crash.
  #
  # The armed timer is deliberately left alone. A stray message is not a flush
  # and not a record, so there is nothing new to flush and nothing to arm.
  def handle_info(message, state) do
    Logger.warning("broker request log: unexpected message #{shape(message)}; ignoring")

    {:noreply, state}
  end

  # The tag and the arity, never the payload. A `{:record, row}` that got here
  # holds a host and a path, and this module's whole point is that the log is
  # redacted — a fallback that inspected the term would be the one place a raw
  # one reached the node's logs.
  defp shape(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "#{inspect(elem(message, 0))}/#{tuple_size(message)}"

  defp shape(message) when is_atom(message), do: inspect(message)
  defp shape(_message), do: "an unrecognized term"

  @impl GenServer
  def terminate(_reason, state) do
    write(state)
    :ok
  end

  defp arm(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @flush_ms)}

  defp arm(state), do: state

  defp write(%{buffer: []} = state), do: disarm(state)

  defp write(state) do
    rows = Enum.reverse(state.buffer)

    try do
      Repo.insert_all(Request, rows)
    rescue
      error ->
        Logger.warning(
          "broker request log: #{length(rows)} row(s) lost: #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.warning(
          "broker request log: #{length(rows)} row(s) lost: #{inspect({kind, reason})}"
        )
    end

    disarm(%{state | buffer: [], size: 0})
  end

  defp disarm(%{timer: nil} = state), do: state

  defp disarm(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
