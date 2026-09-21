defmodule Fountain.PlatformChatGPT.Tokens do
  @moduledoc """
  What Fountain reads out of, and writes into, the tokens a ChatGPT sign-in
  produces (ADR 0047).

  Codex base64-decodes JWT payloads and never checks a signature
  (`codex-rs/login/src/token_data.rs`). It reads `email` and, under the
  `https://api.openai.com/auth` claim, `chatgpt_account_id`,
  `chatgpt_user_id` and `chatgpt_plan_type`. That is the whole of what this
  module extracts from a real `id_token` and the whole of what it puts into
  the one it synthesises for a sandbox: an unsigned three-segment token
  carrying those three claims and no email, so the admin's real identity
  token never enters a sandbox.
  """

  @auth_claim "https://api.openai.com/auth"

  # `{"alg":"none"}`, base64url without padding.
  @unsigned_header "eyJhbGciOiJub25lIn0"

  @doc "The `https://api.openai.com/auth` claim name codex reads."
  def auth_claim, do: @auth_claim

  @doc """
  The payload of a JWT, decoded and never verified. `:error` for anything
  that is not three dot-separated segments with a base64url JSON object in
  the middle.
  """
  @spec decode_payload(String.t()) :: {:ok, map()} | :error
  def decode_payload(jwt) when is_binary(jwt) do
    with [_header, payload, _signature] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  # Kept total on purpose. A `FunctionClauseError` carries its arguments, and
  # Oban stores a job's blamed exception in `oban_jobs.errors`: without this
  # clause a token that is not a binary would be written there by
  # `Fountain.Workers.ChatGPTLinkAttempt` (ADR 0060, "Stage 4a as built").
  def decode_payload(_jwt), do: :error

  @doc """
  The claims codex reads from an `id_token`, as a map with string keys:
  `"account_id"`, `"user_id"`, `"plan_type"` (from the auth claim) and
  `"email"`. `{:error, :invalid_id_token}` when the token does not decode or
  carries no account id, which is the one claim the request path needs.
  """
  @spec claims(String.t()) :: {:ok, map()} | {:error, :invalid_id_token}
  def claims(id_token) do
    with {:ok, payload} <- decode_payload(id_token),
         auth when is_map(auth) <- Map.get(payload, @auth_claim, %{}),
         account_id when is_binary(account_id) and account_id != "" <-
           Map.get(auth, "chatgpt_account_id") do
      {:ok,
       %{
         "account_id" => account_id,
         "user_id" => Map.get(auth, "chatgpt_user_id"),
         "plan_type" => Map.get(auth, "chatgpt_plan_type"),
         "email" => Map.get(payload, "email")
       }}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  @doc """
  When an access token expires, from its `exp` claim; `nil` for a token that
  is not a JWT or carries none (a workspace access token), which the caller
  treats as "stands until refused, or until the expiry the admin set".
  """
  @spec expires_at(String.t()) :: DateTime.t() | nil
  def expires_at(access_token) do
    with {:ok, payload} <- decode_payload(access_token),
         exp when is_integer(exp) <- Map.get(payload, "exp"),
         {:ok, at} <- DateTime.from_unix(exp) do
      at
    else
      _ -> nil
    end
  end

  @doc """
  The `id_token` a sandbox gets: unsigned, three segments, carrying only the
  three claims codex reads under the auth claim. Built from the stored
  `id_claims`, never from the admin's real token.
  """
  @spec synthesize_id_token(map()) :: String.t()
  def synthesize_id_token(claims) when is_map(claims) do
    payload =
      %{
        @auth_claim => %{
          "chatgpt_account_id" => Map.get(claims, "account_id"),
          "chatgpt_user_id" => Map.get(claims, "user_id"),
          "chatgpt_plan_type" => Map.get(claims, "plan_type")
        }
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    @unsigned_header <> "." <> payload <> ".x"
  end

  @doc """
  The tokens out of an `auth.json` that `codex login` wrote on a laptop.
  Codex 0.93.0 is the supported producer floor: its login writer sets
  `auth_mode` explicitly. Only `auth_mode: "chatgpt"` with a non-empty
  refresh token is accepted:
  an `apiKey` file is a key, not a grant, and `chatgptAuthTokens` is what
  Fountain writes, not what it takes in.
  """
  @spec parse_auth_json(String.t()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t(), id_token: String.t()}}
          | {:error, :invalid_auth_json | :not_a_chatgpt_login | :no_refresh_token}
  def parse_auth_json(json) when is_binary(json) do
    with {:ok, %{"tokens" => tokens} = file} when is_map(tokens) <- Jason.decode(json),
         :ok <- chatgpt_mode(file),
         {:ok, refresh} <- refresh_token(tokens),
         access when is_binary(access) and access != "" <- Map.get(tokens, "access_token"),
         id_token when is_binary(id_token) <- Map.get(tokens, "id_token", "") do
      {:ok, %{access_token: access, refresh_token: refresh, id_token: id_token}}
    else
      {:error, reason} when reason in [:not_a_chatgpt_login, :no_refresh_token] ->
        {:error, reason}

      _ ->
        {:error, :invalid_auth_json}
    end
  end

  def parse_auth_json(_json), do: {:error, :invalid_auth_json}

  defp refresh_token(tokens) do
    case Map.get(tokens, "refresh_token") do
      refresh when is_binary(refresh) and refresh != "" -> {:ok, refresh}
      _ -> {:error, :no_refresh_token}
    end
  end

  defp chatgpt_mode(%{"auth_mode" => "chatgpt"}), do: :ok
  defp chatgpt_mode(_file), do: {:error, :not_a_chatgpt_login}
end
