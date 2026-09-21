defmodule Fountain.ChatGPTAccounts.RefreshBreaker do
  @moduledoc """
  A per-node pause on the keepalive's renewals while `auth.openai.com` is
  turning this server's address away (ADR 0060 stage 5).

  Every grant is renewed from the same address. A throttle on that address is
  every tenant's problem at once, and going on at the same rate would make it
  worse, so `Fountain.Workers.ChatGPTGrantKeepalive` waits while this stands.
  A turn's own renewal never asks it: that one is wanted now.

  **One tenant must not be able to stand it up**, because what it holds back
  is everybody else's keepalive. Whether the auth server throttles by address
  or by account has not been measured, so a refusal is taken as evidence and
  not as proof:

    * `ChatGPTAccounts` reports a refusal (`observe/2`) only for a 429, or
      for a 403 whose body names no code at all, which is what a proxy in
      front of the auth server sends. A 403 that names a code is about that
      account and is an ordinary failed refresh.
    * It opens only when refusals have been seen for **two different owners**
      within `@window_ms`. The deployment's own grant counts as an owner. One
      account, however many grants it holds and however often it asks, is
      one owner.
    * A grant is heard once per window. A turn loop that renews the same
      grant every few seconds adds nothing after its first refusal.
    * Once open it lasts `:chatgpt_refresh_breaker_ms` and is extended only
      by the same two-owner evidence. The job caps how long it will wait on
      its side as well, and then goes ahead as a probe.

  It holds a deadline and, for ten minutes each, two hashes per refusal: the
  grant's and the owner's. No id, no token, no part of a response.

  Per node and approximate, as `Fountain.LogThrottle` is: another replica
  learns of a throttle from its own refused calls, and two processes that
  report in the same instant may both write, which costs nothing. A
  `Retry-After` header is not read.

  Internal configuration, application env with no environment variable:
  `:chatgpt_refresh_breaker_ms`, how long it stays open, fifteen minutes.
  (`:chatgpt_keepalive_spacing_ms` is the sweep's, and is described there.)
  """

  @table :fountain_chatgpt_refresh_breaker
  @open :open_until
  @default_ms :timer.minutes(15)
  @window_ms :timer.minutes(10)
  @owners_to_open 2

  @doc """
  The auth server refused `grant_id`'s renewal in the way a throttled address
  is refused. `owner` is the owning user's id, or `:platform`. Opens the
  breaker when this makes two owners within the window; `:ignored` when this
  grant was already heard from within it.
  """
  @spec observe(String.t() | :platform, String.t()) :: :recorded | :opened | :ignored
  def observe(owner, grant_id)
      when (is_binary(owner) or owner == :platform) and is_binary(grant_id) do
    now = now_ms()
    grant = {:seen, :erlang.phash2({:grant, grant_id})}
    :telemetry.execute([:fountain, :chatgpt, :refresh, :rate_limited], %{count: 1}, %{})

    with true <- table?(),
         :ets.select_delete(@table, [
           {{{:seen, :_}, :_, :"$1"}, [{:"=<", :"$1", now - @window_ms}], [true]}
         ]),
         true <- :ets.insert_new(@table, {grant, :erlang.phash2({:owner, owner}), now}) do
      if owners_seen() >= @owners_to_open, do: open(now), else: :recorded
    else
      _ -> :ignored
    end
  end

  @doc "Seconds until the breaker clears, rounded up; `0` when it is not standing."
  @spec remaining_seconds() :: non_neg_integer()
  def remaining_seconds do
    case table?() && :ets.lookup(@table, @open) do
      [{@open, until}] -> max(0, div(until - now_ms() + 999, 1000))
      _ -> 0
    end
  end

  @doc "Whether renewals that can wait should."
  @spec open?() :: boolean()
  def open?, do: remaining_seconds() > 0

  @doc false
  def reset do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp open(now) do
    :ets.insert(@table, {@open, now + pause_ms()})
    :telemetry.execute([:fountain, :chatgpt, :refresh, :breaker_opened], %{count: 1}, %{})
    :opened
  end

  defp owners_seen do
    @table
    |> :ets.match({{:seen, :_}, :"$1", :_})
    |> Enum.uniq()
    |> length()
  end

  defp pause_ms, do: Application.get_env(:fountain, :chatgpt_refresh_breaker_ms, @default_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  # `Table` below owns it, from the application tree. There is no fallback
  # that makes one here: it would belong to whichever process reported first,
  # a refresh task, and go when that did. Without the table the breaker is
  # simply not standing.
  defp table?, do: :ets.whereis(@table) != :undefined

  defmodule Table do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

    @impl true
    def init(:ok) do
      :ets.new(:fountain_chatgpt_refresh_breaker, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

      {:ok, %{}}
    end
  end
end
