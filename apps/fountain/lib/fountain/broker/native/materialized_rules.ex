defmodule Fountain.Broker.Native.MaterializedRules do
  @moduledoc """
  Bounded, node-local decryption cache, never an authorization cache.

  Callers must read current durable authority before every fetch. The key
  includes tenant, encrypted rules, wrapped DEK and master-key identity;
  deletion, expiry and policy are checked outside this cache. No invalidation
  broadcast is needed for correctness, including across network partitions.
  Entries expire after 30 seconds, with a sweep every second, and the cache
  holds at most 1024 results of at most 64 KiB each. Restarting it is a cold
  cache. Hits read ETS directly; misses serialize and recheck the cache so
  concurrent requests decrypt a given value once.
  """
  use GenServer

  @ttl 30_000
  @limit 1024
  @max_bytes 65_536

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def fetch(key, load) do
    case cached(key) do
      {:ok, _} = result -> result
      :miss -> GenServer.call(__MODULE__, {:fetch, key, load})
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :protected, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, 1_000)
    {:ok, nil}
  end

  @impl true
  def handle_call({:fetch, key, load}, _from, state) do
    result =
      case cached(key) do
        {:ok, _} = result ->
          result

        :miss ->
          result = load_safely(load)
          sweep()
          remember(key, result)
          result
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, 1_000)
    {:noreply, state}
  end

  defp cached(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, key) do
      [{^key, expires, value}] when expires > now -> {:ok, value}
      _ -> :miss
    end
  end

  defp sweep do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(__MODULE__, [{{:_, :"$1", :_}, [{:"=<", :"$1", now}], [true]}])
  end

  defp remember(key, {:ok, value}) do
    if :erlang.external_size(value) <= @max_bytes do
      if :ets.info(__MODULE__, :size) >= @limit do
        {oldest, _, _} = __MODULE__ |> :ets.tab2list() |> Enum.min_by(&elem(&1, 1))
        :ets.delete(__MODULE__, oldest)
      end

      :ets.insert(__MODULE__, {key, System.monotonic_time(:millisecond) + @ttl, value})
    end
  end

  defp remember(_key, _result), do: :ok

  defp load_safely(load) do
    load.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
