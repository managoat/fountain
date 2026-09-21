defmodule Fountain.LogThrottle do
  @moduledoc """
  A warning that something untrusted can cause at will, logged at most once
  per key per minute on this node.

  The broker authorizes every egress request of a managed session
  (`Fountain.Broker.Native.Sessions.authorize/2`), and the sandbox decides how
  many of those there are. When the owner's key will not load or the stored
  token will not open, every one of them fails the same way, and a line per
  request would hand the sandbox the log's volume. The first line says
  everything the thousandth would: the key names what is broken (a session,
  a grant and field), and nothing about the request is in it.

  This is for that shape only. A failure an operator has to see every time,
  or one nothing untrusted can repeat, is an ordinary `Logger` call.

  Per node and approximate: two processes that fail in the same instant may
  both log. The table holds the keys that logged within the last interval;
  older ones are dropped whenever a line is written, so it is bounded by what
  is failing now and not by what has ever failed.
  """

  require Logger

  @table :fountain_log_throttle
  @interval_ms 60_000

  @doc "Log `message` as a warning unless `key` already logged within the last minute."
  @spec warning(term(), String.t()) :: :ok
  def warning(key, message) when is_binary(message), do: throttled(:warning, key, message)

  @doc """
  The same at `error`, for a failure an operator must see and that an outage
  repeats once per tenant: the first line says it, and a counter says how
  many.
  """
  @spec error(term(), String.t()) :: :ok
  def error(key, message) when is_binary(message), do: throttled(:error, key, message)

  defp throttled(level, key, message) do
    now = System.monotonic_time(:millisecond)

    if due?(key, now) do
      :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now - @interval_ms}], [true]}])
      :ets.insert(@table, {key, now})
      Logger.log(level, message)
    end

    :ok
  end

  defp due?(key, now) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, at}] -> now - at >= @interval_ms
      [] -> true
    end
  end

  @doc false
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # Owned by `Fountain.LogThrottle.Table`; a caller that runs before the tree
  # is up (or a test without it) gets a table of its own.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    true
  catch
    :error, :badarg -> true
  end

  defmodule Table do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

    @impl true
    def init(:ok) do
      if :ets.whereis(:fountain_log_throttle) == :undefined do
        :ets.new(:fountain_log_throttle, [:named_table, :public, :set, read_concurrency: true])
      end

      {:ok, %{}}
    end
  end
end
