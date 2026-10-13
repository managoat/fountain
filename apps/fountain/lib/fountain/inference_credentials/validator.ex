defmodule Fountain.InferenceCredentials.Validator do
  @moduledoc """
  Lightweight provider ping to validate inference credentials before persisting.

  Each provider exposes a cheap "list models" or "me" style endpoint that
  authenticates the supplied credential without consuming meaningful quota.
  Called from the Settings LiveView on save, so
  users find out about typos / revoked keys at the boundary instead of
  mid-conversation.

  All requests use a 5s timeout; network blips return `{:error, :timeout}`.
  Provider-side rejection (401/403/etc.) returns `{:error, :invalid}` with
  the upstream status as `:status` in the metadata.

  ## Mocking in tests

  In `:test`, the `Req` plug `Fountain.InferenceCredentials.Validator.TestStub`
  is installed (see `test/support/`). Production reads no app config — the
  Req calls go straight to the providers.
  """

  @timeout 5_000

  @type provider ::
          :anthropic_api_key | :claude_code_oauth_token | :openai_api_key | :gemini_api_key
  @type result ::
          :ok
          | {:error, :invalid, %{status: integer()}}
          | {:error, :timeout}
          | {:error, atom()}

  @doc """
  Validate a credential by calling the provider.
  """
  @spec validate(provider(), String.t()) :: result()
  def validate(_provider, ""), do: {:error, :empty}
  def validate(_provider, nil), do: {:error, :empty}

  def validate(:anthropic_api_key, key) when is_binary(key) do
    request("https://api.anthropic.com/v1/models",
      headers: [
        {"x-api-key", key},
        {"anthropic-version", "2023-06-01"}
      ]
    )
  end

  def validate(:claude_code_oauth_token, token) when is_binary(token) do
    # Claude Code OAuth tokens authenticate via Bearer against the same Anthropic
    # API surface for read-only metadata calls. /v1/models is the cheapest probe.
    request("https://api.anthropic.com/v1/models",
      headers: [
        {"authorization", "Bearer " <> token},
        {"anthropic-version", "2023-06-01"}
      ]
    )
  end

  def validate(:openai_api_key, key) when is_binary(key) do
    request("https://api.openai.com/v1/models",
      headers: [{"authorization", "Bearer " <> key}]
    )
  end

  def validate(:gemini_api_key, key) when is_binary(key) do
    # Google AI Studio (Gemini) — API key is passed as a query param, not header.
    request("https://generativelanguage.googleapis.com/v1beta/models?key=" <> URI.encode(key))
  end

  ## Private

  defp request(url, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])

    case Req.get(url,
           headers: headers,
           receive_timeout: @timeout,
           connect_options: [timeout: @timeout],
           retry: false
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, :invalid, %{status: status}}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _other} ->
        {:error, :network}
    end
  end
end
