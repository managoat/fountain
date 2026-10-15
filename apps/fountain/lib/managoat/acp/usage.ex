defmodule Managoat.ACP.Usage do
  @moduledoc """
  The end-of-turn token figure, normalised from a `session/prompt` response
  (#827).

  Three places a runtime puts it, tried in order:

    * `usage` — the (unstable, as of protocol v1) `Usage` object:
      `inputTokens`, `outputTokens`, `cachedReadTokens`, `cachedWriteTokens`,
      `totalTokens`, `thoughtTokens`. claude-agent-acp ≥ 0.6x fills it with
      the turn's accumulated API usage (reset when the turn starts) and
      older codex-acp versions with the thread's last token count;
    * `_meta.quota.token_count` — gemini-cli's own place for it, snake-cased
      and outside the protocol. See `from_meta_quota/1`;
    * `_meta.inputTokens` / `_meta.outputTokens` — where an adapter put it
      before the field had a name.

  The result is a string-keyed map (so it can go straight into a JSON column): `%{"input" => n, "output" => n}` plus `"cache_read"` /
  `"cache_write"` when reported. `nil` when the response carries none of them — a turn without a
  usage, not a zero one.

  An adapter's `_meta.usageAccounting` is preserved as `"accounting"`, with
  only `version`, `source`, `scope`, and `completeness`. These are the adapter's
  claims, not independently verified billing. A metadata-only result carries
  no token keys. Missing or invalid metadata stays absent; historical reports
  gain no invented scope or completeness.

  Deliberately *not* derived from the `usage_update` notifications that
  stream during a turn: those are context-window occupancy (`used` / `size`)
  and a cumulative session `cost`, and what they mean per update differs by
  runtime. The one figure recorded per turn is the one the runtime reports
  when the turn ends.
  """

  @type accounting :: %{
          required(String.t()) => pos_integer() | String.t()
        }
  @type t :: %{optional(String.t()) => non_neg_integer() | accounting()}

  @doc "The turn's usage from a `session/prompt` result, or nil."
  @spec from_prompt_result(map() | nil) :: t() | nil
  def from_prompt_result(%{} = result) do
    counts = prompt_counts(result)

    case accounting_from_prompt_result(result) do
      nil -> counts
      accounting -> Map.put(counts || %{}, "accounting", accounting)
    end
  end

  def from_prompt_result(_), do: nil

  defp prompt_counts(%{"usage" => %{} = usage}), do: normalize(usage)
  defp prompt_counts(%{"_meta" => %{} = meta}), do: from_meta_quota(meta) || normalize(meta)
  defp prompt_counts(_), do: nil

  defp accounting_from_prompt_result(%{
         "_meta" => %{
           "usageAccounting" => %{
             "version" => version,
             "source" => source,
             "scope" => scope,
             "completeness" => completeness
           }
         }
       })
       when is_integer(version) and version > 0 and is_binary(source) and
              byte_size(source) in 1..256 and is_binary(scope) and byte_size(scope) in 1..256 and
              completeness in ["reported", "partial"] do
    %{
      "version" => version,
      "source" => source,
      "scope" => scope,
      "completeness" => completeness
    }
  end

  defp accounting_from_prompt_result(_), do: nil

  @doc """
  gemini-cli's usage, from `_meta.quota.token_count`, or nil.

  **A workaround for one runtime**, registered as
  `:gemini_usage_in_meta_quota` in `Managoat.Runtimes.Quirks`; it is a public
  function so that deleting it is what the registry notices.

  gemini-cli leaves the protocol's `usage` field empty and reports the turn's
  tokens under a vendor `_meta` extension of its own, snake-cased, on every
  `session/prompt` return except `cancelled`:

      %{"stopReason" => "end_turn",
        "_meta" => %{"quota" => %{
          "token_count" => %{"input_tokens" => 1234, "output_tokens" => 567},
          "model_usage" => [...]}}}

  google-gemini/gemini-cli#24280 asked for the standard fields and was closed
  with no plans to add them, so reading this shape is the only way a host
  bills a gemini turn at all.

  `model_usage` — the same counts split per model, for a turn that switched —
  is deliberately not read: the figure recorded per turn is the turn's total,
  and the host already knows which model it asked for.

  **No cache split.** gemini's `promptTokenCount` includes cached tokens and
  the adapter passes no `cachedContentTokenCount` through, so cached input
  arrives inside `"input"` and a caller pricing it pays the base input rate
  for it. That over-states rather than invents, which is the direction to err.
  """
  @spec from_meta_quota(map()) :: t() | nil
  def from_meta_quota(%{"quota" => %{"token_count" => %{} = counts}}) do
    input = count(counts["input_tokens"])
    output = count(counts["output_tokens"])

    if is_nil(input) and is_nil(output) do
      nil
    else
      %{"input" => input || 0, "output" => output || 0}
    end
  end

  def from_meta_quota(_meta), do: nil

  defp normalize(source) do
    input = count(source["inputTokens"])
    output = count(source["outputTokens"])

    if is_nil(input) and is_nil(output) do
      nil
    else
      %{"input" => input || 0, "output" => output || 0}
      |> put_present("cache_read", count(source["cachedReadTokens"]))
      |> put_present("cache_write", count(source["cachedWriteTokens"]))
    end
  end

  # An adapter that reports a float or a numeric string still counts;
  # anything else (a negative, a bool, an object) is "not reported".
  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(n) when is_float(n) and n >= 0, do: trunc(n)

  defp count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp count(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
