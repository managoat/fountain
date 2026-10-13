defmodule Fountain.ChatGPT.Tokens do
  @moduledoc """
  What Fountain reads out of the tokens a ChatGPT sign-in produces, and the
  `id_token` it synthesises for a sandbox.

  Codex base64-decodes JWT payloads and never checks a signature
  (`codex-rs/login/src/token_data.rs`). It reads, under the
  `https://api.openai.com/auth` claim, `chatgpt_account_id`,
  `chatgpt_user_id` and `chatgpt_plan_type`. Those three are all this module
  extracts, and all the synthesised token carries: the real `id_token`
  (with the account's email) never enters a sandbox.
  """

  @auth_claim "https://api.openai.com/auth"

  # `{"alg":"none"}`, base64url without padding.
  @unsigned_header "eyJhbGciOiJub25lIn0"

  @doc "A JWT's payload, decoded and never verified; `:error` for anything else."
  @spec decode_payload(term()) :: {:ok, map()} | :error
  def decode_payload(jwt) when is_binary(jwt) do
    with [_header, payload, _signature] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  def decode_payload(_jwt), do: :error

  @doc """
  The claims codex reads from an `id_token`: `account_id`, `chatgpt_user_id`
  and `plan_type`. `{:error, :invalid_id_token}` without an account id, the
  one claim a request needs.
  """
  @spec claims(term()) ::
          {:ok, %{account_id: String.t(), chatgpt_user_id: term(), plan_type: term()}}
          | {:error, :invalid_id_token}
  def claims(id_token) do
    with {:ok, payload} <- decode_payload(id_token),
         auth when is_map(auth) <- Map.get(payload, @auth_claim, %{}),
         account_id when is_binary(account_id) and account_id != "" <-
           Map.get(auth, "chatgpt_account_id") do
      {:ok,
       %{
         account_id: account_id,
         chatgpt_user_id: string(Map.get(auth, "chatgpt_user_id")),
         plan_type: string(Map.get(auth, "chatgpt_plan_type"))
       }}
    else
      _ -> {:error, :invalid_id_token}
    end
  end

  @doc "When an access token expires, from its `exp` claim; nil when it has none."
  @spec expires_at(term()) :: DateTime.t() | nil
  def expires_at(access_token) do
    with {:ok, payload} <- decode_payload(access_token),
         exp when is_integer(exp) <- Map.get(payload, "exp"),
         {:ok, at} <- DateTime.from_unix(exp) do
      at
    else
      _ -> nil
    end
  end

  @doc "The unsigned `id_token` a sandbox gets, carrying only the three claims."
  @spec synthesize_id_token(map()) :: String.t()
  def synthesize_id_token(%{account_id: account_id} = claims) do
    payload =
      %{
        @auth_claim => %{
          "chatgpt_account_id" => account_id,
          "chatgpt_user_id" => Map.get(claims, :chatgpt_user_id),
          "chatgpt_plan_type" => Map.get(claims, :plan_type)
        }
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    @unsigned_header <> "." <> payload <> ".x"
  end

  @doc """
  The tokens out of an `auth.json` that `codex login` wrote. Only
  `auth_mode: "chatgpt"` with a refresh token is accepted: an API-key file is
  a key, and `chatgptAuthTokens` is what Fountain writes into a sandbox.
  """
  @spec parse_auth_json(term()) ::
          {:ok, %{access_token: String.t(), refresh_token: String.t(), id_token: String.t()}}
          | {:error, :invalid_auth_json | :not_a_chatgpt_login | :no_refresh_token}
  def parse_auth_json(json) when is_binary(json) do
    with {:ok, %{"tokens" => tokens} = file} when is_map(tokens) <- Jason.decode(json),
         {:mode, "chatgpt"} <- {:mode, file["auth_mode"]},
         {:refresh, refresh} when is_binary(refresh) and refresh != "" <-
           {:refresh, tokens["refresh_token"]},
         access when is_binary(access) and access != "" <- tokens["access_token"],
         id_token when is_binary(id_token) <- Map.get(tokens, "id_token", "") do
      {:ok, %{access_token: access, refresh_token: refresh, id_token: id_token}}
    else
      {:mode, _} -> {:error, :not_a_chatgpt_login}
      {:refresh, _} -> {:error, :no_refresh_token}
      _ -> {:error, :invalid_auth_json}
    end
  end

  def parse_auth_json(_json), do: {:error, :invalid_auth_json}

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil
end
