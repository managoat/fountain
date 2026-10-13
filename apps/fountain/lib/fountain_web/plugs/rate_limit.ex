defmodule FountainWeb.Plugs.RateLimit do
  @moduledoc """
  Lightweight ETS-based fixed-window rate limiter. This is a coarse abuse
  control, not a per-account quota — the goal is to stop a buggy or hostile
  client from spamming sprite spawns or saturating the BEAM, not to meter
  individual accounts.

  Buckets are per-IP by default, or per API key with `key: :api_key` on a
  plug that runs after `TenantAPIAuth`. The per-key shape exists because an
  address is not a client: every app deployed beside the server reaches it
  through the same ingress, so one address is several clients sharing a
  bucket (and hiding behind each other), while one client's runaway loop
  (2026-09-04: 14 list calls a second, for four days) is invisible to a
  limit that only counts addresses.

  The ETS table is created in `Fountain.Application` startup. Returns 429 +
  `Retry-After` (seconds) when the bucket is full. The table is per node,
  so a limit is per replica.

  ## Options

    * `:bucket` — string label so multiple plug invocations don't share a
      counter (e.g. an "api" bucket and a "conversations" bucket).
    * `:max` — maximum requests per window.
    * `:window_ms` — window length in ms (default 60_000).
    * `:key` — `:ip` (default) or `:api_key`. With `:api_key`, the bucket is
      the id of `conn.assigns.current_api_key`; a request that reaches the
      plug without one (the plug runs before auth) falls back to the
      address, so a misordered pipeline still limits something.

  ## Example

      pipeline :authed_api do
        plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 120
      end

      scope "/api", FountainWeb do
        post "/conversations", ConversationController, :create
        plug FountainWeb.Plugs.RateLimit, bucket: "conv-create", max: 10
      end
  """

  import Plug.Conn

  # Table name inherited from an earlier project; renaming it is a behavior
  # change (persistent named table), so it stays.
  @table :aod_rate_limit

  def table, do: @table

  @doc "Create the ETS table. Idempotent — safe to call from app startup."
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        :ok
    end
  end

  @doc """
  Delete rows whose window started more than `max_age_ms` ago.

  A row older than its bucket's window no longer affects any decision —
  `bump/2` resets it on the next hit — so eviction is invisible to
  limiting behavior as long as `max_age_ms` is at least the longest
  window configured anywhere. Returns the number of rows deleted.
  """
  def evict_expired(max_age_ms) do
    ensure_table()
    cutoff = System.system_time(:millisecond) - max_age_ms
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
  end

  def init(opts) do
    key = Keyword.get(opts, :key, :ip)

    if key not in [:ip, :api_key] do
      raise ArgumentError, "RateLimit key must be :ip or :api_key, got: #{inspect(key)}"
    end

    %{
      bucket: Keyword.fetch!(opts, :bucket),
      max: Keyword.fetch!(opts, :max),
      window_ms: Keyword.get(opts, :window_ms, 60_000),
      key: key
    }
  end

  def call(conn, opts) do
    ensure_table()
    key = key_for(conn, opts)

    case bump(key, opts) do
      :ok ->
        conn

      {:limited, retry_after_secs} ->
        conn
        |> put_resp_header("retry-after", to_string(retry_after_secs))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{error: "rate_limited", retry_after_seconds: retry_after_secs})
        )
        |> halt()
    end
  end

  # Exposed for tests.
  @doc false
  def bump(key, opts) do
    now = System.system_time(:millisecond)
    cutoff = now - opts.window_ms

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, now, 1})
        :ok

      [{^key, started_at, _count}] when started_at < cutoff ->
        :ets.insert(@table, {key, now, 1})
        :ok

      [{^key, _started_at, count}] when count < opts.max ->
        :ets.update_counter(@table, key, {3, 1})
        :ok

      [{^key, started_at, _count}] ->
        retry_ms = opts.window_ms - (now - started_at)
        {:limited, max(div(retry_ms, 1000), 1)}
    end
  end

  # Exposed for tests: the bucket key a request lands in.
  @doc false
  def key_for(conn, %{bucket: bucket, key: :api_key}) do
    case conn.assigns[:current_api_key] do
      %{id: id} when is_binary(id) -> isolate_key({bucket, id})
      _ -> isolate({bucket, format_ip(conn.remote_ip)})
    end
  end

  def key_for(conn, %{bucket: bucket}) do
    isolate({bucket, format_ip(conn.remote_ip)})
  end

  # In test isolation mode, key by the calling process PID as well. This
  # prevents async ExUnit tests from sharing rate limit counters while still
  # allowing dedicated rate-limit tests to accumulate counts naturally (all
  # requests in a test run in the same process). The PID replaces the
  # address — every test's conn has the same loopback address — and joins
  # the key id, so a per-key test still sees two keys as two buckets.
  defp isolate({bucket, _ip} = key) do
    if Application.get_env(:fountain, :rate_limit_test_isolation, false) do
      {bucket, self()}
    else
      key
    end
  end

  defp isolate_key({bucket, id}) do
    if Application.get_env(:fountain, :rate_limit_test_isolation, false) do
      {bucket, id, self()}
    else
      {bucket, id}
    end
  end

  defp format_ip(nil), do: "unknown"
  defp format_ip(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(other), do: to_string(other)
end
