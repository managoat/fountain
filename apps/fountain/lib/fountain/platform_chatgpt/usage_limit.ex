defmodule Fountain.PlatformChatGPT.UsageLimit do
  @moduledoc """
  Whether the deployment's ChatGPT account has really spent its Codex usage
  (#2362), asked of OpenAI rather than of the sandbox.

  ## A report from the sandbox is only a hint

  codex-acp answers a refused `session/prompt` with a JSON-RPC internal
  error whose `data.codexErrorInfo` is `"usageLimitExceeded"`, and
  `Managoat.ACP.Peer` reports it as `{:failed, {:acp_error, :prompt, error}}`.
  `hint?/1` recognises that shape. It is **never** evidence: the adapter runs
  in a tenant's sandbox, and a tenant's `setup_script` can replace it with a
  program that answers any prompt with this error without contacting
  OpenAI. The grant is shared by every tenant, so a hint only asks the
  server to check.

  ## The check

  `fetch/2` asks `GET https://chatgpt.com/backend-api/wham/usage` with the
  grant's access token and its `ChatGPT-Account-Id`: the endpoint Codex's
  own client reads its rate limits from (`codex-rs/backend-client`,
  `rate_limit_status_url/0`, read 2026-09-16). The server makes the call over
  TLS with a token the sandbox never holds, so nothing in a sandbox can shape
  the answer. The body carries

      %{"rate_limit" => %{"allowed" => false, "limit_reached" => true,
          "primary_window" => %{"used_percent" => 100, "reset_at" => 1790163600,
                                "reset_after_seconds" => 322_000, ...},
          "secondary_window" => ...},
        "credits" => %{"has_credits" => false, "unlimited" => false}}

  and `limited/2` reads it: limited when `allowed` is false, or when
  `limit_reached` is true with no credits to spend instead. The reset is the
  latest `reset_at` (else `now + reset_after_seconds`) of the windows at 100
  percent, or of every window when none says so. A limited account with no
  usable reset gets `default_window_seconds/0`; one further out than
  `max_window_seconds/0` is cut to it. Anything else, including a failed or
  unexpected response, is not a limit.
  """

  @default_window_seconds 3_600
  @max_window_seconds 8 * 86_400
  @default_base_url "https://chatgpt.com/backend-api"

  @doc "How long a confirmed limit with no usable reset time lasts: one hour."
  @spec default_window_seconds() :: pos_integer()
  def default_window_seconds, do: @default_window_seconds

  @doc "The furthest a confirmed reset is trusted: eight days, one more than Codex's weekly window."
  @spec max_window_seconds() :: pos_integer()
  def max_window_seconds, do: @max_window_seconds

  @doc """
  Whether a failed prompt's error claims Codex's usage limit. A hint to
  check, never a fact: see the moduledoc.
  """
  @spec hint?(term()) :: boolean()
  def hint?(%{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}}), do: true
  def hint?(error), do: error |> inspect() |> String.contains?("usageLimitExceeded")

  @doc """
  Ask the ChatGPT backend for the account's Codex usage.
  `{:limited, until}`, `:not_limited`, or `{:error, reason}` when the
  answer could not be had or read; only the first is a limit.
  """
  @spec fetch(String.t(), String.t() | nil, DateTime.t()) ::
          {:limited, DateTime.t()} | :not_limited | {:error, term()}
  def fetch(access_token, account_id, now \\ DateTime.utc_now())
      when is_binary(access_token) do
    headers =
      [
        {"authorization", "Bearer " <> access_token},
        {"accept", "application/json"},
        {"user-agent", "codex-cli"}
      ] ++ if(is_binary(account_id), do: [{"chatgpt-account-id", account_id}], else: [])

    [
      url: base_url() <> "/wham/usage",
      headers: headers,
      connect_options: [timeout: 2_000],
      receive_timeout: 6_000,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:fountain, :platform_chatgpt_req_options, []))
    |> Req.new()
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> limited(body, now)
      {:ok, %Req.Response{status: status}} -> {:error, {:usage, status}}
      {:error, reason} -> {:error, {:usage, reason}}
    end
  end

  @doc "Read a `/wham/usage` body. See the moduledoc."
  @spec limited(map(), DateTime.t()) :: {:limited, DateTime.t()} | :not_limited | {:error, term()}
  def limited(%{"rate_limit" => %{} = rate_limit} = body, now) do
    now = DateTime.truncate(now, :second)

    if limited?(rate_limit, Map.get(body, "credits")) do
      {:limited, reset(rate_limit, now)}
    else
      :not_limited
    end
  end

  def limited(_body, _now), do: {:error, :unexpected_usage_body}

  defp limited?(%{"allowed" => false}, _credits), do: true

  defp limited?(%{"limit_reached" => true}, credits) do
    not match?(%{"has_credits" => true}, credits) and
      not match?(%{"unlimited" => true}, credits)
  end

  defp limited?(_rate_limit, _credits), do: false

  defp reset(rate_limit, now) do
    windows =
      ["primary_window", "secondary_window"]
      |> Enum.map(&Map.get(rate_limit, &1))
      |> Enum.filter(&is_map/1)

    spent = Enum.filter(windows, &(is_number(&1["used_percent"]) and &1["used_percent"] >= 100))

    if(spent == [], do: windows, else: spent)
    |> Enum.map(&window_reset(&1, now))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.max(DateTime, fn -> DateTime.add(now, @default_window_seconds, :second) end)
    |> cap(DateTime.add(now, @max_window_seconds, :second))
    |> DateTime.truncate(:second)
  end

  defp cap(at, limit), do: if(DateTime.compare(at, limit) == :gt, do: limit, else: at)

  defp window_reset(%{"reset_at" => at}, _now) when is_integer(at) and at > 0,
    do: DateTime.from_unix!(at)

  defp window_reset(%{"reset_after_seconds" => seconds}, now)
       when is_integer(seconds) and seconds > 0,
       do: DateTime.add(now, seconds, :second)

  defp window_reset(_window, _now), do: nil

  defp base_url do
    Application.get_env(:fountain, :platform_chatgpt_backend_url, @default_base_url)
    |> String.trim_trailing("/")
  end
end
