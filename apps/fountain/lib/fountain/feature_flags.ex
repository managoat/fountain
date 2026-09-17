defmodule Fountain.FeatureFlags do
  @moduledoc """
  Per-user feature flags, evaluated by PostHog and safe when PostHog is not.

  `enabled?(flag, user)` answers a yes/no for one user. The sources, in order:

  1. **Static overrides** — `config :fountain, :feature_flag_overrides,
     %{"connections" => true}` (from `FEATURE_FLAGS_ON=connections,...` in
     `config/runtime.exs`). A self-hoster with no PostHog turns a feature on
     for everyone this way; tests use it to flip a flag without any HTTP.
  2. **PostHog** — `POST {host}/flags/?v=2` with the project API key and the
     user's id as `distinct_id`, when `POSTHOG_PROJECT_API_KEY` is set. The
     answer for the whole user is cached in ETS for `@fresh_ms`.
  3. **The last answer PostHog gave**, however old, when the call fails —
     timeout, 5xx, DNS. A flag that was on stays on across a PostHog outage
     and a flag that was off stays off; the outage does not flip anything.
  4. **Off.** No override, no PostHog (or PostHog unreachable with nothing
     cached) → `false`. Fail closed: an unreachable flag service must never
     turn a feature on. The one exception is `@on_without_posthog`, the flags
     that gate a shipped feature rather than an unfinished one: those read on
     where the deployment configured no PostHog at all.

  The lookup is bounded — `@timeout_ms` — so a slow PostHog costs a request
  at most that much once per user per `@fresh_ms`, not on every call. The
  cache is a plain ETS table owned by `Fountain.FeatureFlags.Cache`; readers
  never touch the GenServer.

  Flags are plain strings, the PostHog key as written in its UI. Keep the
  known ones in `@flags` so a typo is a compile-time `KeyError`, not a flag
  that is silently always off.
  """

  require Logger

  @table :fountain_feature_flags
  @fresh_ms 60_000
  @timeout_ms 2_000

  @flags %{
    # Provider registration and credential bindings have their own rollout.
    connections: "connections"
  }

  # The flags that read **on** where there is no PostHog to ask.
  #
  # "Off because we asked and were told no" and "off because there is nobody
  # to ask" are different answers, and only the first one is a decision. Rule
  # 4 above fails closed on both, which is right for a flag that gates an
  # unfinished feature: nobody loses anything they had. It is wrong for a flag
  # that gates a **shipped** one, because a self-host configures no PostHog —
  # so the flag reads off there forever and the feature disappears on the
  # upgrade that introduced the flag (#1620, #1693). A flag listed here is on
  # for a deployment with no `POSTHOG_PROJECT_API_KEY`, and is answered by
  # PostHog like any other wherever one is configured. `FEATURE_FLAGS_ON`
  # still wins over both, and so does a PostHog answer of "off".
  #
  # "Shipped" here means the feature is built and supported, not that every
  # account has it. Membership says nothing about the rollout wherever a
  # PostHog **is** configured: on the hosted platform `connections` is an
  # Alpha enrolled per account (`docs/reference/feature-status.md`), and the
  # flag's release conditions there are the only thing that decides who. What
  # membership does buy is `warn_undefined/2` below — because a key this list
  # names and the project has never heard of is a mistake, not a decision.
  @on_without_posthog Map.new([:connections], &{Map.fetch!(@flags, &1), true})

  @doc "The PostHog key for a known flag atom."
  def key!(flag) when is_atom(flag), do: Map.fetch!(@flags, flag)

  @doc """
  Whether `flag` is on for `user` — a `%Fountain.Accounts.User{}`, a user id
  string, or `nil` (no user: only the answers that are the same for everyone
  apply, the static overrides and `@on_without_posthog`).
  """
  @spec enabled?(atom | String.t(), term) :: boolean
  def enabled?(flag, user) when is_atom(flag), do: enabled?(key!(flag), user)

  def enabled?(flag, user) when is_binary(flag) do
    id = distinct_id(user)

    answer =
      case Map.fetch(overrides(), flag) do
        {:ok, value} -> value == true
        :error -> remote_enabled?(flag, id)
      end

    report_called(flag, id, answer)
    answer
  end

  # PostHog's own SDKs capture `$feature_flag_called` every time a flag is
  # read, which is what makes "the flag is on for 40 accounts but only 3 ever
  # hit the code path" answerable. Rate-limited to one event per person per
  # flag per `@fresh_ms` for the same reason the lookup itself is cached: a
  # flag read on every request must not become an event on every request.
  defp report_called(_flag, nil, _answer), do: :ok

  defp report_called(flag, distinct_id, answer) do
    now = System.monotonic_time(:millisecond)
    key = {:called, distinct_id, flag}

    if stale?(key, now) do
      ensure_table()
      :ets.insert(@table, {key, answer, now})

      Fountain.Analytics.capture("$feature_flag_called", distinct_id, %{
        "$feature_flag" => flag,
        "$feature_flag_response" => answer
      })
    end

    :ok
  end

  # Shared by the `$feature_flag_called` capture and by `warn_once/2`: has it
  # been `@fresh_ms` since this key was last written to the table?
  defp stale?(key, now) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, _value, at}] -> now - at >= @fresh_ms
      [] -> true
    end
  end

  @doc """
  The answers already held for this person, without ever making a call.

  `Fountain.Analytics` stamps these onto every event as `$feature/<key>` so a
  cohort can be compared against its control at query time. Cache-only on
  purpose: capturing an event must never be the thing that triggers a flag
  lookup, and a person who has not had a flag read yet simply carries no flag
  properties.
  """
  @spec cached_flags(String.t() | nil) :: %{String.t() => boolean()}
  def cached_flags(distinct_id) when is_binary(distinct_id) do
    remote =
      case cached(distinct_id) do
        {:ok, flags, _at} -> flags
        :miss -> %{}
      end

    Map.merge(remote, overrides())
  end

  def cached_flags(_), do: %{}

  defp distinct_id(%{id: id}) when is_binary(id), do: id
  defp distinct_id(id) when is_binary(id), do: id
  defp distinct_id(_), do: nil

  defp remote_enabled?(flag, distinct_id) do
    cond do
      not configured?() ->
        Map.get(@on_without_posthog, flag, false)

      is_nil(distinct_id) ->
        false

      true ->
        {source, flags} = answered_flags(distinct_id)
        if source == :answered, do: warn_undefined(flag, flags)
        Map.get(flags, flag, false) == true
    end
  end

  # A flag PostHog has never heard of is **absent** from its answer; a flag it
  # has and says no to comes back present and `false`. Rule 4 fails closed on
  # both, so the two look identical at the call site — but for a flag in
  # `@on_without_posthog` the first one is a mistake in the analytics project
  # rather than a rollout decision, and it switches off a feature this code
  # treats as built, for every account, with nothing logged anywhere. That is
  # how Connections sat dark on production from the day the flag shipped until
  # someone ran the deployed suite against it (#2347).
  #
  # The same silence covers a flag that exists with `evaluation_runtime` set
  # to `server`: this call carries the project token, which PostHog reads as a
  # client-side evaluation, so a server-only flag never appears in the answer
  # and is indistinguishable from one that was never created.
  #
  # Only a real answer can say a key is missing. An unreachable PostHog with
  # nothing cached yields an empty map, which is not evidence of anything —
  # `answered_flags/1` has already logged the outage, and calls this with
  # `:unanswered`, which does not reach here.
  defp warn_undefined(flag, flags) do
    if Map.has_key?(@on_without_posthog, flag) and not Map.has_key?(flags, flag) do
      warn_once(
        {:undefined, flag},
        ~s(feature flags: #{flag} gates a built feature, but PostHog's answer does not ) <>
          ~s(mention it, so it reads off for every account. Either no flag has that key ) <>
          ~s(in the project, or its evaluation_runtime is "server" rather than "all". ) <>
          ~s(Create it, widen it, or set FEATURE_FLAGS_ON=#{flag}.)
      )
    end

    :ok
  end

  # Rate-limited like `$feature_flag_called`, and for the same reason: a flag
  # read on every request must not become a log line on every request.
  defp warn_once(key, message) do
    now = System.monotonic_time(:millisecond)

    if stale?(key, now) do
      ensure_table()
      :ets.insert(@table, {key, :logged, now})
      Logger.error(message)
    end

    :ok
  end

  @doc "Every flag PostHog reports on for the user, `%{key => boolean}`."
  def flags_for(distinct_id) when is_binary(distinct_id) do
    {_answered, flags} = answered_flags(distinct_id)
    flags
  end

  # The flags, and whether they are PostHog's own answer. A cached answer is
  # still an answer, stale or not — it came from a response PostHog sent about
  # this person. Only a failed lookup with nothing cached is `:unanswered`.
  defp answered_flags(distinct_id) do
    now = System.monotonic_time(:millisecond)

    case cached(distinct_id) do
      {:ok, flags, at} when now - at < @fresh_ms ->
        {:answered, flags}

      cached ->
        case fetch(distinct_id) do
          {:ok, flags} ->
            put(distinct_id, flags, now)
            {:answered, flags}

          {:error, reason} ->
            Logger.warning(
              "feature flags: PostHog lookup failed (#{inspect(reason)}); " <>
                stale_note(cached)
            )

            case cached do
              {:ok, flags, _at} -> {:answered, flags}
              :miss -> {:unanswered, %{}}
            end
        end
    end
  end

  defp stale_note({:ok, _, _}), do: "using the last answer"
  defp stale_note(:miss), do: "no cached answer, every flag reads off"

  @doc "Drop every cached answer (tests, or after an operator flips a flag)."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  ## PostHog

  @doc false
  def configured?, do: is_binary(api_key()) and api_key() != ""

  defp api_key, do: Application.get_env(:fountain, :posthog_project_api_key)

  defp host, do: Application.get_env(:fountain, :posthog_host, "https://us.i.posthog.com")

  defp overrides, do: Application.get_env(:fountain, :feature_flag_overrides, %{})

  defp fetch(distinct_id) do
    req =
      Req.new(
        [
          base_url: host(),
          receive_timeout: @timeout_ms,
          connect_options: [timeout: @timeout_ms],
          retry: false
        ] ++ Application.get_env(:fountain, :posthog_req_options, [])
      )

    case Req.post(req, url: "/flags/?v=2", json: %{api_key: api_key(), distinct_id: distinct_id}) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, parse(body)}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # `/flags?v=2` answers `{"flags": {key: {"enabled": bool, ...}}}`; the
  # older `/decide?v=3` shape is `{"featureFlags": {key: bool | variant}}`.
  # Read both so a host pinned to the old endpoint still works.
  defp parse(%{"flags" => flags}) when is_map(flags) do
    Map.new(flags, fn
      {k, %{"enabled" => enabled}} -> {k, enabled == true}
      {k, v} -> {k, v == true}
    end)
  end

  defp parse(%{"featureFlags" => flags}) when is_map(flags) do
    Map.new(flags, fn {k, v} -> {k, v == true or is_binary(v)} end)
  end

  defp parse(_), do: %{}

  ## cache

  defp cached(distinct_id) do
    ensure_table()

    case :ets.lookup(@table, distinct_id) do
      [{^distinct_id, flags, at}] -> {:ok, flags, at}
      [] -> :miss
    end
  end

  defp put(distinct_id, flags, at) do
    ensure_table()
    :ets.insert(@table, {distinct_id, flags, at})
  end

  @doc false
  def table, do: @table

  # The table is owned by `Fountain.FeatureFlags.Cache`; a caller that runs
  # before the tree is up (or a test without it) gets a table of its own.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    true
  catch
    :error, :badarg -> true
  end

  defmodule Cache do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

    @impl true
    def init(:ok) do
      table = Fountain.FeatureFlags.table()

      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
      end

      {:ok, %{}}
    end
  end
end
