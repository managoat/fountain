defmodule Fountain.ChatGPTAccounts.RefreshBreaker do
  @moduledoc """
  A per-node pause on the keepalive's renewals after `auth.openai.com` has
  turned this server's address away (ADR 0060 stage 5).

  Every user's grant is renewed from the same address. A 429, or a 403 that
  names no terminal code, is the auth server throttling that address and not
  a verdict on one grant, so going on at the same rate would cost every
  tenant at once. `ChatGPTAccounts` trips this when a user grant's refresh is
  answered that way, from whichever path asked, and
  `Fountain.Workers.ChatGPTGrantKeepalive` snoozes instead of calling while
  it stands. A turn's own renewal does not ask it: that one is wanted now,
  and there are few of them.

  It holds one monotonic deadline and nothing else: no grant, no owner, no
  part of a response. It clears by time alone; the first job after it has
  cleared is the probe, and a second refusal stands it up again.

  Per node and approximate, as `Fountain.LogThrottle` is: another replica
  learns of the throttle from its own first refused call. With the refresh
  queue at two per node that is a couple of requests per replica, which is
  the price of not putting a row in the database on this path. A
  `Retry-After` header is not read.
  """

  @table :fountain_chatgpt_refresh_breaker
  @key :open_until
  @default_ms :timer.minutes(15)

  @doc "Stand the breaker up for `ms` from now. A later trip extends it, never shortens it."
  @spec trip(pos_integer()) :: :ok
  def trip(ms \\ pause_ms()) when is_integer(ms) and ms > 0 do
    ensure_table()
    until = now_ms() + ms

    case :ets.lookup(@table, @key) do
      [{@key, standing}] when standing >= until -> :ok
      _ -> :ets.insert(@table, {@key, until})
    end

    :telemetry.execute([:fountain, :chatgpt, :refresh, :rate_limited], %{count: 1}, %{})
    :ok
  end

  @doc "Seconds until the breaker clears, rounded up; `0` when it is not standing."
  @spec remaining_seconds() :: non_neg_integer()
  def remaining_seconds do
    ensure_table()

    case :ets.lookup(@table, @key) do
      [{@key, until}] -> max(0, div(until - now_ms() + 999, 1000))
      [] -> 0
    end
  end

  @doc "Whether renewals that can wait should."
  @spec open?() :: boolean()
  def open?, do: remaining_seconds() > 0

  @doc false
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp pause_ms, do: Application.get_env(:fountain, :chatgpt_refresh_breaker_ms, @default_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Owned by `Table` below; a caller that runs before the tree is up gets a
  # table of its own.
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
      if :ets.whereis(:fountain_chatgpt_refresh_breaker) == :undefined do
        :ets.new(:fountain_chatgpt_refresh_breaker, [
          :named_table,
          :public,
          :set,
          read_concurrency: true
        ])
      end

      {:ok, %{}}
    end
  end
end
