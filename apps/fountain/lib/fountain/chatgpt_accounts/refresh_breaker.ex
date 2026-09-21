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
      for a 403 whose body is not a JSON object at all (HTML, empty, a bare
      string), which is what a proxy in front of the auth server sends. A
      403 with a JSON object body is the auth server talking about that
      account, whether or not `OAuth` can read a code in it, and is an
      ordinary failed refresh.
    * It opens only when refusals have been seen for **two different owners**
      within `@window_ms`. The deployment's own grant counts as an owner. One
      account, however many grants it holds and however often it asks, is
      one owner.
    * A grant is heard once per window. A turn loop that renews the same
      grant every few seconds adds nothing after its first refusal.
    * Once open it lasts `:chatgpt_refresh_breaker_ms` and is extended only
      by the same two-owner evidence.
    * **It is half-open, one probe per node per pause length.** A job that
      has been held long enough asks `claim_probe/0`; one wins, for the next
      fifteen minutes, and makes the one request. The rest go on waiting.
    * **A renewal that succeeds closes it** (`succeeded/0`), from whichever
      path and for whichever owner: a 200 from this address is better
      evidence than any refusal that the address is not throttled. It takes
      the refusals heard so far with it, since the success refutes them. So
      a probe that succeeds lets every held job run at its next wake.

  It holds a deadline and, for ten minutes each, two hashes per refusal: the
  grant's and the owner's. No id, no token, no part of a response.

  Per node and approximate, as `Fountain.LogThrottle` is: another replica
  learns of a throttle from its own refused calls, and two processes that
  report in the same instant may both open it and both be counted, which
  costs nothing. A `Retry-After` header is not read. Nothing here raises: it
  is called from inside a turn's renewal, and if the table's owner has just
  died the breaker is simply not standing.

  Internal configuration, application env with no environment variable:
  `:chatgpt_refresh_breaker_ms`, how long it stays open, fifteen minutes; and
  `:chatgpt_refresh_breaker_now_ms`, a test's clock.
  (`:chatgpt_keepalive_spacing_ms` is the sweep's, and is described there.)
  """

  @table :fountain_chatgpt_refresh_breaker
  @open :open_until
  @probe :probe
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
    :telemetry.execute([:fountain, :chatgpt, :refresh, :rate_limited], %{count: 1}, %{})

    :ets.select_delete(@table, [
      {{{:seen, :_}, :_, :"$1"}, [{:"=<", :"$1", now - @window_ms}], [true]}
    ])

    cond do
      not :ets.insert_new(@table, {seen_key(grant_id), :erlang.phash2({:owner, owner}), now}) ->
        :ignored

      owners_seen() >= @owners_to_open ->
        :ets.insert(@table, {@open, now + pause_ms()})
        :telemetry.execute([:fountain, :chatgpt, :refresh, :breaker_opened], %{count: 1}, %{})
        :opened

      true ->
        :recorded
    end
  rescue
    ArgumentError -> :ignored
  end

  @doc """
  A renewal from this address succeeded, so the address is not throttled:
  the breaker closes, and the refusals heard so far go with it. `:closed`
  when it was standing, else `:ok`.
  """
  @spec succeeded() :: :closed | :ok
  def succeeded do
    was_open? = open?()
    if :ets.info(@table, :size) > 0, do: :ets.delete_all_objects(@table)

    if was_open? do
      :telemetry.execute([:fountain, :chatgpt, :refresh, :breaker_closed], %{count: 1}, %{})
      :closed
    else
      :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Ask to be the one probe. `:claimed` for one caller per pause length
  (`:chatgpt_refresh_breaker_ms`) while the breaker stands, `:taken` for the
  rest, `:closed` when it is not standing. Counted from the claim and not
  from the pause's start, because a probe that is refused is itself evidence
  and extends the pause: were the claim the pause's, that refusal would hand
  the next job a probe at once.
  """
  @spec claim_probe() :: :claimed | :taken | :closed
  def claim_probe do
    now = now_ms()
    pause = pause_ms()

    case :ets.lookup(@table, @open) do
      [{@open, until}] when until > now ->
        case :ets.lookup(@table, @probe) do
          [{@probe, at}] when now - at < pause ->
            :taken

          _ ->
            :ets.delete(@table, @probe)
            if :ets.insert_new(@table, {@probe, now}), do: :claimed, else: :taken
        end

      _ ->
        :closed
    end
  rescue
    ArgumentError -> :closed
  end

  @doc "Whether `grant_id`'s refusal is on record within the window. For tests and an operator's shell."
  @spec heard?(String.t()) :: boolean()
  def heard?(grant_id) when is_binary(grant_id) do
    case :ets.lookup(@table, seen_key(grant_id)) do
      [{_, _, at}] -> at > now_ms() - @window_ms
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Seconds until the breaker clears, rounded up; `0` when it is not standing."
  @spec remaining_seconds() :: non_neg_integer()
  def remaining_seconds do
    case :ets.lookup(@table, @open) do
      [{@open, until}] -> max(0, div(until - now_ms() + 999, 1000))
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Whether renewals that can wait should."
  @spec open?() :: boolean()
  def open?, do: remaining_seconds() > 0

  @doc false
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp seen_key(grant_id), do: {:seen, :erlang.phash2({:grant, grant_id})}

  defp owners_seen do
    @table
    |> :ets.match({{:seen, :_}, :"$1", :_})
    |> Enum.uniq()
    |> length()
  end

  defp pause_ms, do: Application.get_env(:fountain, :chatgpt_refresh_breaker_ms, @default_ms)

  # Monotonic milliseconds. `:chatgpt_refresh_breaker_now_ms` replaces the
  # clock with a number, for a test that has to see a window or a pause pass.
  defp now_ms do
    Application.get_env(:fountain, :chatgpt_refresh_breaker_now_ms) ||
      System.monotonic_time(:millisecond)
  end

  # The table is `Table`'s below, from the application tree. There is no
  # fallback that makes one here: it would belong to whichever process
  # reported first, a refresh task, and go when that did. Every `:ets` call
  # above raises `ArgumentError` when the table is not there, and every
  # function rescues it into "not standing".

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
