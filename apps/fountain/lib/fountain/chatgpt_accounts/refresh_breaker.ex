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
    * Once open it lasts `:chatgpt_refresh_breaker_ms` and is extended by
      the same two-owner evidence, or by a probe that is refused.
    * **It is half-open, one probe per node per pause length.** A job that
      has been held long enough asks `claim_probe/0`; one wins, for the next
      fifteen minutes, and makes the one request. The rest go on waiting. A
      probe that made no request gives the turn back (`release_probe/0`).
    * **A probe that is refused keeps it open** (`probe_refused/0`), on its
      own: it was made while the breaker stood, so it is the one refusal
      that is about the address whoever's grant it was. It stands for two
      pause lengths from then, so that the next probe, one pause length
      after this one, is made before it lapses. While some job is due to
      probe, a throttle that lasts is one request per pause length. When
      none is, it lapses, and the jobs that wake then call until two owners
      have been refused again.
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
  costs nothing. A `Retry-After` header is not read. Its opening is one
  `error` line through `Fountain.LogThrottle`, with how many owners were
  heard and nothing of who they are. Nothing here raises: it
  is called from inside a turn's renewal, and if the table's owner has just
  died the breaker is simply not standing.

  Internal configuration, application env with no environment variable:
  `:chatgpt_refresh_breaker_ms`, how long it stays open, fifteen minutes; and
  `:chatgpt_refresh_breaker_now_ms`, a test's clock, which is read only in a
  build whose config set `:chatgpt_refresh_breaker_test_clock` at compile
  time (`config/test.exs` does): set anywhere else it does nothing, where it
  would have stopped the clock.
  (`:chatgpt_keepalive_spacing_ms` is the sweep's, and is described there.)
  """

  @table :fountain_chatgpt_refresh_breaker
  @open :open_until
  @probe :probe
  @default_ms :timer.minutes(15)
  @window_ms :timer.minutes(10)
  @owners_to_open 2
  @refused_probe_pauses 2

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
        opened(owners_seen())
        :opened

      true ->
        :recorded
    end
  rescue
    ArgumentError -> :ignored
  end

  # An owner or a grant id of another shape is nobody's evidence, and this is
  # called from inside a turn's renewal, which a clause error would end.
  def observe(_owner, _grant_id), do: :ignored

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
  from the pause's start, because a probe that is refused extends the pause
  (`probe_refused/0`): were the claim the pause's, that refusal would hand
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

          stale ->
            # The claim that was read, and no other: a plain delete here
            # could take away the claim another caller made a moment ago,
            # and both would be the probe.
            Enum.each(stale, &:ets.delete_object(@table, &1))
            if :ets.insert_new(@table, {@probe, now}), do: :claimed, else: :taken
        end

      _ ->
        :closed
    end
  rescue
    ArgumentError -> :closed
  end

  @doc """
  The probe was refused as a throttled address is. The breaker stands for two
  pause lengths from now, the next probe being one pause length after this
  one's claim. `:ok` when it no longer stood: a success closed it while the
  probe was out, and the success is the better evidence.
  """
  @spec probe_refused() :: :extended | :ok
  def probe_refused do
    now = now_ms()

    case :ets.lookup(@table, @open) do
      [{@open, until}] when until > now ->
        :ets.insert(@table, {@open, max(until, now + @refused_probe_pauses * pause_ms())})
        :extended

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The probe asked the auth server nothing (its renewal was crowded out, or
  its grant can no longer be renewed), so the turn goes back for the next
  job that is due. Only the job that was answered `:claimed` calls this.
  """
  @spec release_probe() :: :ok
  def release_probe do
    :ets.delete(@table, @probe)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Seconds until `claim_probe/0` can next answer `:claimed`, rounded up; `0` when it can now."
  @spec probe_seconds() :: non_neg_integer()
  def probe_seconds do
    case :ets.lookup(@table, @probe) do
      [{@probe, at}] -> max(0, div(at + pause_ms() - now_ms() + 999, 1000))
      _ -> 0
    end
  rescue
    ArgumentError -> 0
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

  # The one line that says a throttle has begun: until now only a counter
  # did, and the first `error` line was the three-day stop. Once a minute at
  # most, and a count: no owner, no grant.
  defp opened(owners) do
    Fountain.LogThrottle.error(
      {:chatgpt_refresh, :breaker_opened},
      "chatgpt refresh: auth.openai.com turned this address away for #{owners} owners within " <>
        "ten minutes, so this node's keepalive renewals wait, #{div(pause_ms(), 60_000)} " <>
        "minutes at first and for as long as its probes are refused " <>
        "(fountain_chatgpt_refresh_breaker_opened_count)"
    )
  end

  defp pause_ms, do: Application.get_env(:fountain, :chatgpt_refresh_breaker_ms, @default_ms)

  # Monotonic milliseconds. `:chatgpt_refresh_breaker_now_ms` replaces the
  # clock with a number, for a test that has to see a window or a pause pass,
  # and only in a build that was compiled to allow it: a production node on
  # which the key were ever set would otherwise have a clock that stood still.
  if Application.compile_env(:fountain, :chatgpt_refresh_breaker_test_clock, false) do
    defp now_ms do
      Application.get_env(:fountain, :chatgpt_refresh_breaker_now_ms) ||
        System.monotonic_time(:millisecond)
    end
  else
    defp now_ms, do: System.monotonic_time(:millisecond)
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
