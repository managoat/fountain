defmodule Fountain.ChatGPT.OAuth do
  @moduledoc """
  The calls to `auth.openai.com` a ChatGPT sign-in for codex needs: the
  refresh, and the three legs of the device-code flow. Read from
  `codex-rs/login/src/auth/manager.rs` and `device_code_auth.rs`; the client
  id is Codex's own public one. Kept from the retired implementation (ADR
  0047, 0060), where it ran in production from 2026-09-08.

  The refresh token rotates: a successful refresh hands back a new one. The
  server names terminal codes, which become `{:error, {:terminal, code}}` so
  the caller can mark the subscription revoked rather than retry a token that
  will never work again.

  `:chatgpt_auth_url` and `:chatgpt_req_options` are config so a test never
  reaches the real server.
  """

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @default_base_url "https://auth.openai.com"
  @device_redirect_uri "https://auth.openai.com/deviceauth/callback"

  # Measured 2026-09-08 (ADR 0047 G0): a burnt token is a 401
  # `refresh_token_reused`, a mangled one a 400
  # `invalid_refresh_token_ciphertext_integrity`. The code decides, not the
  # status.
  @terminal ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated invalid_grant invalid_refresh_token_ciphertext_integrity)

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil
        }

  # Every leg is bounded at about eighteen seconds end to end: Finch checks
  # `:request_timeout` between receives and each receive may block for a full
  # `:receive_timeout`, so the ceiling is their sum plus connect and pool.
  # `:request_timeout` applies to HTTP/1 only, hence the protocol pin.
  @finch [
    conn_opts: [transport_opts: [timeout: 2_000]],
    protocols: [:http1],
    pool_timeout: 1_000,
    receive_timeout: 6_000,
    request_timeout: 9_000
  ]

  @doc """
  Exchange a refresh token for a fresh set. `{:error, {:terminal, code}}`
  when the server says the token will never work again; any other failure is
  transient and the caller keeps what it has.
  """
  @spec refresh(String.t()) :: {:ok, tokens()} | {:error, {:terminal, String.t()} | term()}
  def refresh(refresh_token) when is_binary(refresh_token) do
    post("/oauth/token", %{
      client_id: @client_id,
      grant_type: "refresh_token",
      refresh_token: refresh_token
    })
    |> token_response()
  end

  @doc "Leg one of the device flow: a user code, the id to poll with, the interval and the page."
  @spec device_start() ::
          {:ok,
           %{
             user_code: String.t(),
             device_auth_id: String.t(),
             interval: pos_integer(),
             verification_url: String.t()
           }}
          | {:error, term()}
  def device_start do
    case post("/api/accounts/deviceauth/usercode", %{client_id: @client_id}) do
      {:ok, %{status: 200, body: %{"user_code" => code, "device_auth_id" => id} = body}}
      when is_binary(code) and is_binary(id) ->
        {:ok,
         %{
           user_code: code,
           device_auth_id: id,
           interval: interval(Map.get(body, "interval")),
           verification_url: base_url() <> "/codex/device"
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_start, status, error_code(body)}}

      {:error, reason} ->
        {:error, {:device_start, reason}}
    end
  end

  @doc """
  Leg two: has the code been approved yet? `:pending` on the 403 and 404 the
  server answers with until then.
  """
  @spec device_poll(String.t(), String.t()) ::
          {:ok, %{authorization_code: String.t(), code_verifier: String.t()}}
          | :pending
          | {:error, term()}
  def device_poll(device_auth_id, user_code) do
    case post("/api/accounts/deviceauth/token", %{
           device_auth_id: device_auth_id,
           user_code: user_code
         }) do
      {:ok, %{status: 200, body: %{"authorization_code" => code} = body}} when is_binary(code) ->
        {:ok, %{authorization_code: code, code_verifier: Map.get(body, "code_verifier", "")}}

      {:ok, %{status: status}} when status in [403, 404] ->
        :pending

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_poll, status, error_code(body)}}

      {:error, reason} ->
        {:error, {:device_poll, reason}}
    end
  end

  @doc "Leg three: the standard code exchange, with the device flow's fixed redirect."
  @spec device_exchange(%{authorization_code: String.t(), code_verifier: String.t()}) ::
          {:ok, tokens()} | {:error, term()}
  def device_exchange(%{authorization_code: code, code_verifier: verifier}) do
    post("/oauth/token", %{
      client_id: @client_id,
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: @device_redirect_uri
    })
    |> token_response()
  end

  # Total on purpose: a response of any other shape is reduced to a status
  # and a code, so no caller ever holds (or logs) a body that might carry a
  # token.
  defp token_response({:ok, %{status: 200, body: %{"access_token" => access} = body}})
       when is_binary(access) and access != "" do
    {:ok,
     %{
       access_token: access,
       refresh_token: present(Map.get(body, "refresh_token")),
       id_token: present(Map.get(body, "id_token"))
     }}
  end

  defp token_response({:ok, %{status: status, body: body}}) do
    case error_code(body) do
      code when code in @terminal -> {:error, {:terminal, code}}
      code -> {:error, {:token, status, code}}
    end
  end

  defp token_response({:error, reason}), do: {:error, {:token, reason}}

  # `{"error": "code"}` or `{"error": {"code": "code"}}`.
  @doc false
  def error_code(%{"error" => code}) when is_binary(code), do: code
  def error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  def error_code(%{"error" => %{"type" => code}}) when is_binary(code), do: code
  def error_code(body) when not is_map(body), do: "unreadable"
  def error_code(_body), do: "unknown"

  # Req's body decoding is off: a JSON body cut short would otherwise come
  # back as a decode error whose `data` is the body, which on a token
  # response is tokens.
  defp post(path, json) do
    [
      url: base_url() <> path,
      json: json,
      headers: [{"accept", "application/json"}],
      retry: false,
      finch: @finch
    ]
    |> Keyword.merge(Application.get_env(:fountain, :chatgpt_req_options, []))
    |> Keyword.put(:decode_body, false)
    |> Req.new()
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: status} = response} ->
        {:ok, %{status: status, body: decoded(response)}}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  defp decoded(%Req.Response{body: body} = response) when is_binary(body) and body != "" do
    with [type | _] <- Req.Response.get_header(response, "content-type"),
         true <- String.contains?(type, "json"),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> body
    end
  end

  defp decoded(%Req.Response{body: body}), do: body

  defp base_url do
    Application.get_env(:fountain, :chatgpt_auth_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  # Never zero, never more than a minute (where Codex stops backing off).
  defp interval(n) when is_integer(n) and n >= 1, do: min(n, 60)

  defp interval(n) when is_binary(n) do
    case Integer.parse(n) do
      {seconds, ""} -> interval(seconds)
      _ -> 5
    end
  end

  defp interval(_), do: 5

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
end
