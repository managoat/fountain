defmodule Fountain.PlatformChatGPT.UsageLimit do
  @moduledoc """
  Reads a Codex "usage limit" refusal out of a failed prompt (#2362).

  ## Where it arrives

  codex-acp (`@agentclientprotocol/codex-acp`, pinned in
  `Managoat.Runtimes.ACP`) turns the Codex app-server's `error` notification
  into the `session/prompt` response. For `codexErrorInfo:
  "usageLimitExceeded"` that response is a JSON-RPC internal error whose
  `data` carries the kind and the provider's sentence:

      %{"code" => -32603, "message" => "Internal error",
        "data" => %{"codexErrorInfo" => "usageLimitExceeded",
                    "message" => "You've hit your usage limit. Visit
                      https://chatgpt.com/codex/settings/usage to purchase
                      more credits or try again at Sep 20th, 2026 11:40 AM."}}

  `Managoat.ACP.Peer` reports it as `{:failed, {:acp_error, :prompt, error}}`.
  The kind is read off `data.codexErrorInfo` when it is there, and found
  anywhere in the payload otherwise, the way the peer finds
  `oauth_org_not_allowed`: the adapter's placement may move, and a substring
  search cannot raise on a shape nobody anticipated.

  ## The reset time is prose

  The adapter keeps the account's rate-limit snapshot (`resetsAt`, epoch
  seconds) in its own session state and does not send it over ACP, so the
  only reset time Fountain sees is the sentence. Codex formats it in the
  sandbox's local time zone as `Sep 20th, 2026 11:40 AM`, or as `11:40 AM`
  when the reset is the same day. A sandbox runs in UTC, so it is read as
  UTC; a bare time already past today is tomorrow's.

  Parsing is defensive. A sentence with no readable time, a time in the
  past, or one further out than `max_window_seconds/0` gets
  `default_window_seconds/0` from now instead, and says so (`:default`), so
  a change in Codex's wording costs an hour of metered turns rather than a
  week of them or none at all.
  """

  @default_window_seconds 3_600
  @max_window_seconds 8 * 86_400

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @doc "How long the grant is skipped when the refusal names no readable reset time: one hour."
  @spec default_window_seconds() :: pos_integer()
  def default_window_seconds, do: @default_window_seconds

  @doc """
  The furthest a parsed reset is trusted: eight days, one more than Codex's
  weekly window. Anything later is read as a misparse.
  """
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds, do: @max_window_seconds

  @doc "Whether a failed prompt's error is Codex's usage-limit refusal."
  @spec exceeded?(term()) :: boolean()
  def exceeded?(%{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}}), do: true
  def exceeded?(error), do: error |> inspect() |> String.contains?("usageLimitExceeded")

  @doc """
  `{:ok, until, :provider | :default}` for a usage-limit refusal: when the
  grant may be selected again, truncated to the second, and whether that
  came from the provider's sentence. `:none` for any other error.
  """
  @spec exhaustion(term(), DateTime.t()) :: {:ok, DateTime.t(), :provider | :default} | :none
  def exhaustion(error, now \\ DateTime.utc_now()) do
    if exceeded?(error) do
      now = DateTime.truncate(now, :second)

      case reset_at(message(error), now) do
        {:ok, at} ->
          {:ok, at, :provider}

        :error ->
          {:ok, DateTime.add(now, @default_window_seconds, :second), :default}
      end
    else
      :none
    end
  end

  defp message(%{"data" => %{"message" => message}}) when is_binary(message), do: message
  defp message(error), do: inspect(error)

  @full ~r/try again at\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,\s+(\d{4})\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm])/
  @time_only ~r/try again at\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm])/

  defp reset_at(text, now) do
    parsed =
      case Regex.run(@full, text) do
        [_, month, day, year, hour, minute, meridiem] ->
          with {:ok, month} <- month(month),
               {:ok, date} <- Date.new(int(year), month, int(day)),
               {:ok, time} <- time(hour, minute, meridiem) do
            DateTime.new(date, time, "Etc/UTC")
          end

        nil ->
          case Regex.run(@time_only, text) do
            [_, hour, minute, meridiem] ->
              with {:ok, time} <- time(hour, minute, meridiem),
                   {:ok, today} <- DateTime.new(DateTime.to_date(now), time, "Etc/UTC") do
                if DateTime.compare(today, now) == :gt,
                  do: {:ok, today},
                  else: {:ok, DateTime.add(today, 86_400, :second)}
              end

            nil ->
              :error
          end
      end

    with {:ok, at} <- parsed, true <- plausible?(at, now) do
      {:ok, at}
    else
      _ -> :error
    end
  end

  defp plausible?(at, now) do
    seconds = DateTime.diff(at, now, :second)
    seconds > 0 and seconds <= @max_window_seconds
  end

  defp month(name) do
    case Enum.find_index(@months, &(&1 == String.downcase(name))) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  defp time(hour, minute, meridiem) do
    hour = int(hour)
    pm? = String.downcase(meridiem) == "pm"

    hour =
      cond do
        hour == 12 and not pm? -> 0
        hour == 12 -> 12
        pm? -> hour + 12
        true -> hour
      end

    Time.new(hour, int(minute), 0)
  end

  defp int(digits), do: String.to_integer(digits)
end
