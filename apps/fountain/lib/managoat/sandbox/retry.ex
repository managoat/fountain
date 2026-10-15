defmodule Managoat.Sandbox.Retry do
  @moduledoc """
  Bounded exponential backoff for **idempotent** external calls.

  A transient Sprites blip used to fail provisioning outright: sandbox marked
  `failed`, conversation marked `failed`, user retries by hand (#168). Steps
  that are safe to repeat now retry a couple of times before giving up.

  The contract is idempotency, and the retry policy leans on it: an *unknown*
  error shape is retried, because for an idempotent call the cost of a
  pointless retry is milliseconds, while the cost of misclassifying a
  transient transport error as permanent is a failed conversation. Only errors
  that are provably permanent — an HTTP 4xx other than 429 — are not retried.

  Never wrap a non-idempotent call (spawning a runtime turn, a git clone into
  a non-empty directory) in this.
  """

  require Logger

  @default_attempts 3
  @default_max_ms 2_000

  @doc """
  Runs `fun`, retrying on retriable failure with exponential backoff + jitter.

  Retries when `fun` returns `{:error, reason}` with a retriable reason, or
  when it raises (unknown raises are treated as transient, per the moduledoc). Anything else `fun` returns passes through
  untouched. When attempts are exhausted the last error tuple is returned, or
  the last exception re-raised, so call sites keep their existing semantics.

  Options:
    * `:attempts` — total attempts, default #{@default_attempts}
    * `:base_ms` — first delay, default 250 (test config sets it to 1)
    * `:max_ms` — delay ceiling, default #{@default_max_ms}
    * `:label` — for the retry log line
    * `:retriable?` — override the `transient?/1` classifier
  """
  @spec with_backoff((-> result), keyword()) :: result when result: term()
  def with_backoff(fun, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)

    base_ms =
      Keyword.get_lazy(opts, :base_ms, fn ->
        Managoat.Sandbox.Config.get(Managoat.Sandbox.Retry, :base_ms, 250)
      end)

    max_ms = Keyword.get(opts, :max_ms, @default_max_ms)
    label = Keyword.get(opts, :label, "external call")
    retriable? = Keyword.get(opts, :retriable?, &transient?/1)

    attempt(fun, 1, attempts, base_ms, max_ms, label, retriable?)
  end

  defp attempt(fun, n, attempts, base_ms, max_ms, label, retriable?) do
    result =
      try do
        {:returned, fun.()}
      rescue
        e -> {:raised, e, __STACKTRACE__}
      end

    case result do
      {:returned, {:error, reason} = err} ->
        if n < attempts and retriable?.(reason) do
          retry_after(n, base_ms, max_ms, label, reason)
          attempt(fun, n + 1, attempts, base_ms, max_ms, label, retriable?)
        else
          err
        end

      {:returned, other} ->
        other

      {:raised, e, stack} ->
        if n < attempts do
          retry_after(n, base_ms, max_ms, label, e)
          attempt(fun, n + 1, attempts, base_ms, max_ms, label, retriable?)
        else
          reraise e, stack
        end
    end
  end

  defp retry_after(n, base_ms, max_ms, label, reason) do
    delay = delay_ms(n, base_ms, max_ms)

    Logger.warning(
      "retry: #{label} attempt #{n} failed (#{inspect(reason)}), retrying in #{delay}ms"
    )

    Process.sleep(delay)
  end

  # Exponential with full jitter: base * 2^(n-1), capped, then a random slice
  # of it — so concurrent provisions do not retry in lockstep.
  defp delay_ms(n, base_ms, max_ms) do
    ceiling = min(base_ms * Integer.pow(2, n - 1), max_ms)
    max(:rand.uniform(ceiling), div(ceiling, 2))
  end

  @doc """
  Whether an error reason is worth retrying.

  The `Managoat.Sandbox` taxonomy classifies directly: `{:unavailable, _}`
  and `{:rate_limited, _}` are transient; `:not_found`, `{:denied, _}` and
  `{:invalid, _}` are provably permanent, as are `:truncated`,
  `:not_supported` and a reported-failed restore.

  Everything else — `:timeout`, transport exceptions, unknown shapes — is
  treated as transient; see the moduledoc for why unknown defaults to retry.
  """
  @spec transient?(term()) :: boolean()
  def transient?({:unavailable, _detail}), do: true
  def transient?({:rate_limited, _retry_after}), do: true

  def transient?(reason) when reason in [:not_found, :truncated, :not_supported, :already_exists],
    do: false

  def transient?({:denied, _detail}), do: false
  def transient?({:invalid, _detail}), do: false
  def transient?({:restore_failed, _detail}), do: false

  def transient?(_reason), do: true
end
