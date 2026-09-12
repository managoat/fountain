defmodule Fountain.PlatformChatGPT.OAuth do
  @moduledoc """
  The calls to `auth.openai.com` that a ChatGPT sign-in for codex needs
  (ADR 0047): the refresh, and the three legs of the device-code flow. Read
  from `codex-rs/login/src/auth/manager.rs` and `device_code_auth.rs` on
  2026-09-08; the client id is Codex's own public one.

  The refresh token rotates: every successful refresh hands back a new one.
  Measured 2026-09-08, an old one is not refused outright (a reuse forks a
  second chain), but the server does name terminal codes, and this module turns them into `{:error, {:terminal,
  code}}` so the caller can mark the grant revoked with the reason, rather
  than retrying a token that will never work again.

  Base URL and Req options are config so a test never reaches the real
  server (`:platform_chatgpt_auth_url`, `:platform_chatgpt_req_options`).
  """

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @default_base_url "https://auth.openai.com"
  @device_redirect_uri "https://auth.openai.com/deviceauth/callback"

  # The codes the auth server names as terminal, plus the RFC 6749 one, plus
  # the one it answers a corrupted token with. Measured 2026-09-08 (ADR 0047
  # G0): a burnt token is a 401 `refresh_token_reused`, a mangled one a 400
  # `invalid_refresh_token_ciphertext_integrity`, both under
  # `{"error": {"code": ...}}`. The status is not what decides; the code is.
  @terminal ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated invalid_grant invalid_refresh_token_ciphertext_integrity)

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          id_token: String.t() | nil
        }

  @doc "Codex's OAuth client id."
  def client_id, do: @client_id

  @refresh_connect_timeout 2_000
  @refresh_pool_timeout 1_000
  @refresh_receive_timeout 3_000
  @refresh_request_timeout 12_000

  defp refresh_finch_options do
    [
      conn_opts: [transport_opts: [timeout: @refresh_connect_timeout]],
      protocols: [:http1],
      pool_timeout: @refresh_pool_timeout,
      receive_timeout: @refresh_receive_timeout,
      request_timeout: @refresh_request_timeout
    ]
  end

  @doc """
  The longest `refresh/1` can take before it gives up, in milliseconds.

  A **sum**, not a maximum. `:request_timeout` is checked between receives
  and each receive may then block for a full `:receive_timeout`, so a call
  that exhausts the first can still spend the second on one last receive,
  on top of connecting and waiting for a pool slot.

  `Fountain.ChatGPTAccounts.RefreshLock` holds a database checkout for the
  whole exchange, so this number has to stay under its transaction budget.
  `Fountain.ChatGPTRefreshCoordinationTest` asserts exactly that, because
  the two are set in different modules and the arithmetic is not obvious.
  """
  @spec refresh_timeout_ceiling_ms() :: pos_integer()
  def refresh_timeout_ceiling_ms do
    @refresh_request_timeout + @refresh_receive_timeout + @refresh_connect_timeout +
      @refresh_pool_timeout
  end

  @doc """
  The error codes that mean the refresh token will never work again, and so
  the only ones a stored `revoked_reason` can hold. Callers that show a
  reason to a tenant allowlist against this rather than restating it: the
  list moved once already and a copy of it drifted.
  """
  @spec terminal_codes() :: [String.t()]
  def terminal_codes, do: @terminal

  @doc """
  Exchange a refresh token for a fresh set. `{:error, {:terminal, code}}`
  when the server says the token will never work again; any other failure
  is transient and the caller keeps what it has.
  """
  @spec refresh(String.t()) :: {:ok, tokens()} | {:error, {:terminal, String.t()} | term()}
  def refresh(refresh_token) when is_binary(refresh_token) do
    # This call runs inside `Fountain.ChatGPTAccounts.RefreshLock`'s
    # 20-second transaction, holding a database checkout for its whole
    # duration, so its worst case has to be provably smaller than that.
    #
    # `:request_timeout` alone does not bound it. Finch checks it *between*
    # receives and each receive may then block for a full `:receive_timeout`
    # (finch 0.23.0, `http1/conn.ex:298` guards before the `recv` at `:313`),
    # so the ceiling is the two added together, not the larger of them.
    # Measured: a provider dripping for 11s and then going silent took 22.8s
    # under 12/12 and the pool force-disconnected the connection mid-flight.
    # 12 + 3 + 2 + 1 = 18s leaves the transaction two seconds of headroom.
    #
    # `:request_timeout` applies to HTTP/1 only, hence the protocol pin. It
    # is scoped to this exchange: Req starts a separate Finch instance named
    # by a hash of these options, so the shared pool keeps its own settings.
    post(
      "/oauth/token",
      %{
        client_id: @client_id,
        grant_type: "refresh_token",
        refresh_token: refresh_token
      },
      finch: refresh_finch_options(),
      retry: false
    )
    |> token_response()
  end

  @doc """
  Leg one of the device flow: ask for a user code. Returns the code the
  admin types, the id to poll with, the interval the server asked for (in
  seconds) and the page to approve it on.
  """
  @spec device_start() ::
          {:ok,
           %{
             user_code: String.t(),
             device_auth_id: String.t(),
             interval: non_neg_integer(),
             verification_url: String.t()
           }}
          | {:error, term()}
  def device_start do
    case post("/api/accounts/deviceauth/usercode", %{client_id: @client_id}) do
      {:ok, %{status: 200, body: %{"user_code" => code, "device_auth_id" => id} = body}} ->
        {:ok,
         %{
           user_code: code,
           device_auth_id: id,
           interval: interval(Map.get(body, "interval")),
           verification_url: base_url() <> "/codex/device"
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_start, status, redact(body)}}

      {:error, reason} ->
        {:error, {:device_start, reason}}
    end
  end

  @doc """
  Leg two: has the admin approved the code yet? `:pending` on the 403 and
  404 the server answers with until then; `{:ok, grant}` once approved,
  with the authorization code and the PKCE verifier the exchange needs.
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
      {:ok, %{status: 200, body: %{"authorization_code" => code} = body}} ->
        {:ok, %{authorization_code: code, code_verifier: Map.get(body, "code_verifier", "")}}

      {:ok, %{status: status}} when status in [403, 404] ->
        :pending

      {:ok, %{status: status, body: body}} ->
        {:error, {:device_poll, status, redact(body)}}

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

  # ── plumbing ─────────────────────────────────────────────────────────────

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

  # The server answers `{"error": "code"}` or `{"error": {"code": "code"}}`.
  defp error_code(%{"error" => code}) when is_binary(code), do: code
  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(%{"error" => %{"type" => code}}) when is_binary(code), do: code
  defp error_code(_body), do: "unknown"

  defp post(path, json, opts \\ []) do
    [
      url: base_url() <> path,
      json: json,
      headers: [{"accept", "application/json"}],
      receive_timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000),
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:fountain, :platform_chatgpt_req_options, []))
    |> Keyword.merge(opts)
    |> Req.new()
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_url do
    Application.get_env(:fountain, :platform_chatgpt_auth_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  # Never zero: a server that says 0 would have the poll spin. Codex's own
  # floor is positive too.
  defp interval(n) when is_integer(n) and n >= 1, do: n
  defp interval(_), do: 5

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # A failure body is logged by the caller; keep only its error shape, in
  # case a server ever echoes a token back.
  defp redact(%{"error" => _} = body), do: Map.take(body, ["error", "error_description"])
  defp redact(body) when is_map(body), do: Map.keys(body)
  defp redact(_body), do: nil
end
