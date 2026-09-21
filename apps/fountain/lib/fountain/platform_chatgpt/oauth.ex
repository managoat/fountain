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
  @refresh_receive_timeout 6_000
  @refresh_request_timeout 9_000

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
    # 9 + 6 + 2 + 1 = 18s leaves the transaction two seconds of headroom.
    #
    # Split that way round because `:receive_timeout` bounds the *first*
    # receive as well as the gaps: finch enters `receive_response([], ...)`
    # straight after the send (`http1/conn.ex:130`), so it is how long the
    # auth server has to begin answering at all. `:request_timeout` covers
    # the body, and this body is a few hundred bytes. Six seconds of server
    # think time and nine for the whole response beats the reverse.
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
    case post("/api/accounts/deviceauth/usercode", %{client_id: @client_id}, bounded()) do
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
    case post(
           "/api/accounts/deviceauth/token",
           %{device_auth_id: device_auth_id, user_code: user_code},
           bounded()
         ) do
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
    post(
      "/oauth/token",
      %{
        client_id: @client_id,
        grant_type: "authorization_code",
        code: code,
        code_verifier: verifier,
        redirect_uri: @device_redirect_uri
      },
      bounded()
    )
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

  # The two clauses below keep this total, on purpose: a response that is not
  # the shape above falls through to them and is reduced to a status and a
  # code. Were one missing, the `FunctionClauseError` would carry the whole
  # response, tokens included, and Oban stores a job's blamed exception in
  # `oban_jobs.errors` (ADR 0060, "Stage 4a as built").
  defp token_response({:ok, %{status: status, body: body}}) do
    case error_code(body) do
      code when code in @terminal -> {:error, {:terminal, code}}
      code -> {:error, {:token, status, code}}
    end
  end

  defp token_response({:error, reason}), do: {:error, {:token, reason}}

  # The server answers `{"error": "code"}` or `{"error": {"code": "code"}}`.
  # Public for its test only.
  @doc false
  def error_code(%{"error" => code}) when is_binary(code), do: code
  def error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  def error_code(%{"error" => %{"type" => code}}) when is_binary(code), do: code
  # A body that is not a JSON object did not come from the auth server's own
  # error path: an HTML page, nothing, a bare string. A proxy in front of it
  # answers that way, which `ChatGPTAccounts` reads, on a 403, as this
  # address being turned away. An object with no code it can read is
  # `"unknown"`, and says nothing about the address. A body labelled JSON
  # that does not parse (cut short, say) reaches here as the binary it was,
  # `post/3` having kept it, so it is `"unreadable"` with its status.
  def error_code(body) when not is_map(body), do: "unreadable"
  def error_code(_body), do: "unknown"

  # The device flow's legs take the refresh's limits. Nothing holds a database
  # checkout across them, but a user's sign-in is polled from a queue every
  # account shares (`chatgpt`), and `post/3`'s own default sets no connect
  # timeout at all: an auth server that stops answering would otherwise hold a
  # slot for as long as the socket liked.
  defp bounded, do: [finch: refresh_finch_options()]

  # Req's own body decoding is off. It answers a JSON body that does not
  # parse with `{:error, %Jason.DecodeError{}}`: the status is gone, which is
  # what says whether a refusal was a throttled address, and the exception's
  # `data` is the whole body, which on a token response cut short is tokens.
  # `decoded/1` reads the same bodies and keeps the binary when it cannot.
  defp post(path, json, opts) do
    [
      url: base_url() <> path,
      json: json,
      headers: [{"accept", "application/json"}],
      receive_timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000),
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:fountain, :platform_chatgpt_req_options, []))
    |> Keyword.merge(opts)
    |> Keyword.put(:decode_body, false)
    |> Req.new()
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: status} = response} ->
        {:ok, %{status: status, body: decoded(response)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What Req decoded: a body whose content type says JSON, and no other.
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
    Application.get_env(:fountain, :platform_chatgpt_auth_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  # Never zero: a server that says 0 would have the poll spin. Codex's own
  # floor is positive too. Never more than a minute either, which is where
  # Codex stops backing off: a code lives fifteen, and an answer of an hour
  # would poll it once after it had died. A string of digits is taken for
  # what it says rather than silently replaced by the default.
  @max_interval 60

  defp interval(n) when is_integer(n) and n >= 1, do: min(n, @max_interval)

  defp interval(n) when is_binary(n) do
    case Integer.parse(n) do
      {seconds, ""} -> interval(seconds)
      _ -> 5
    end
  end

  defp interval(_), do: 5

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # A failure body is logged by the caller; keep only its error shape, in
  # case a server ever echoes a token back.
  defp redact(%{"error" => _} = body), do: Map.take(body, ["error", "error_description"])
  defp redact(body) when is_map(body), do: Map.keys(body)
  defp redact(_body), do: nil
end
