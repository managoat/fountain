defmodule Fountain.Error do
  @moduledoc "Structured errors returned by the Fountain API and transport."
  defexception [
    :message,
    :code,
    :body,
    :retry_after,
    :kind,
    :conversation_id,
    :partial_text,
    status: 0
  ]

  @type kind ::
          :auth
          | :subscription_required
          | :not_found
          | :validation
          | :rate_limit
          | :conversation_busy
          | :not_ready
          | :quota_exceeded
          | :connection
          | :resolution
          | :timeout
          | :api

  @type t :: %__MODULE__{}

  @retryable_codes ~w(conversation_busy provisioning sprite_probe_failed sandbox_quota_exceeded sandbox_at_capacity rate_limited)
  @hints %{
    400 => "bad request",
    401 => "unauthorized — check the API key",
    402 => "payment required — the account is out of credit",
    403 => "forbidden — the key may lack the scope for this call",
    404 => "not found — wrong id, or it belongs to another account",
    409 => "conflict",
    422 => "rejected",
    429 => "rate limited",
    503 => "temporarily unavailable"
  }

  def retryable?(%__MODULE__{code: code, status: status}),
    do: code in @retryable_codes or status == 429 or status in 500..599

  def field_errors(%__MODULE__{body: %{"errors" => errors}}) when is_map(errors) do
    Map.new(errors, fn {field, value} ->
      values =
        if is_list(value),
          do: Enum.filter(value, &is_binary/1),
          else: if(is_binary(value), do: [value], else: [])

      {field, values}
    end)
  end

  def field_errors(_), do: %{}
  def upgrade_url(%__MODULE__{body: %{"upgrade_url" => url}}) when is_binary(url), do: url
  def upgrade_url(_), do: nil
  def active_sandboxes(%__MODULE__{body: %{"active_sandboxes" => n}}) when is_integer(n), do: n
  def active_sandboxes(_), do: nil
  def limit(%__MODULE__{body: %{"limit" => n}}) when is_integer(n), do: n
  def limit(_), do: nil

  @doc false
  def for_status(status, body, method, url, headers \\ []) do
    code = if is_map(body) and is_binary(body["error"]), do: body["error"]
    detail = detail(body)

    message =
      ["HTTP #{status}", @hints[status], detail, "(#{method} #{url})"]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    %__MODULE__{
      message: message,
      status: status,
      code: code,
      body: body,
      retry_after: retry_after(headers),
      kind: kind(code, status)
    }
  end

  defp kind("conversation_busy", _), do: :conversation_busy

  defp kind(code, _)
       when code in ~w(provisioning sprite_probe_failed fleet_full sandbox_unavailable),
       do: :not_ready

  defp kind("sandbox_quota_exceeded", _), do: :quota_exceeded

  defp kind(code, _) when code in ~w(subscription_required insufficient_credits),
    do: :subscription_required

  defp kind(_, 401), do: :auth
  defp kind(_, 402), do: :subscription_required
  defp kind(_, 404), do: :not_found
  defp kind(_, 422), do: :validation
  defp kind(_, 429), do: :rate_limit
  defp kind(_, _), do: :api

  defp detail(body) when is_map(body) do
    value = body["message"] || body["error"] || body["errors"]
    if is_binary(value), do: value, else: if(is_nil(value), do: "", else: Jason.encode!(value))
  end

  defp detail(body) when is_binary(body), do: body |> String.trim() |> String.slice(0, 300)
  defp detail(_), do: ""

  defp retry_after(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == "retry-after", do: to_string(value)
    end)
    |> case do
      nil ->
        nil

      value ->
        case Float.parse(value) do
          {number, ""} -> number
          _ -> nil
        end
    end
  end
end
