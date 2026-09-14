defmodule Fountain.Connections.OAuth do
  @moduledoc """
  The OAuth 2.0 authorization-code client behind every connection (#1186),
  driven by a `Fountain.Connections.Provider`: the authorize URL, the code
  exchange, the refresh and the revoke. A plain client over `Req`; nothing
  here touches the database, and the provider must already carry its
  plaintext `client_secret` (`Fountain.Connections.unlock_provider/1`).

  What differs per provider is data on the record, not code here — the
  provider's `authorize_params` and `token_body_nest` included (#2152), so
  this module names no service:

    * PKCE (S256) when `pkce` is set — always for `mcp` providers, which also
      send the `resource` parameter (RFC 8707) so the token is bound to the
      server the tenant named.
    * Client authentication at the token endpoint: `client_secret_post`,
      `client_secret_basic` or `none` (a public client).
    * Refresh: a response that carries a new refresh token rotates it; no
      `expires_in` means the access token does not expire; no refresh token
      at all means the connection goes `expired` when the access token does.
    * Revoke: RFC 7009 at `revoke_url` when set; local only otherwise.
    * The account label: `userinfo_url` + `account_label_path`, or nothing,
      in which case the caller names the account.

  Every URL a tenant supplied is checked by `Managoat.McpAuth.UrlGuard`
  again at the moment it is fetched, not only when it was saved.
  """

  alias Fountain.Connections.Provider
  alias Managoat.McpAuth.UrlGuard

  @type grant :: %{
          refresh_token: String.t() | nil,
          access_token: String.t(),
          expires_at: DateTime.t() | nil,
          scopes: [String.t()],
          account_email: String.t() | nil
        }

  @doc "True when the provider has a client Fountain can drive."
  def configured?(%Provider{client_id: id, token_endpoint_auth: "none"}), do: present?(id)

  def configured?(%Provider{client_id: id, client_secret: secret}),
    do: present?(id) and present?(secret)

  defp present?(v), do: is_binary(v) and v != ""

  @doc "A PKCE code verifier: 43 to 128 unreserved characters (RFC 7636)."
  def code_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

  @doc "Where to send the tenant. `verifier` is the PKCE verifier kept in the session, or nil."
  @spec authorize_url(Provider.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def authorize_url(%Provider{} = p, redirect_uri, state, verifier \\ nil)
      when is_binary(redirect_uri) and is_binary(state) do
    base = %{
      "client_id" => p.client_id || "",
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "scope" => Enum.join(p.scopes, " "),
      "state" => state
    }

    query =
      base
      |> Map.merge(p.authorize_params || %{})
      |> Map.merge(pkce_params(p, verifier))
      |> Map.merge(resource_params(p))
      |> URI.encode_query()

    join = if String.contains?(p.authorize_url, "?"), do: "&", else: "?"
    p.authorize_url <> join <> query
  end

  defp pkce_params(%Provider{pkce: true}, verifier) when is_binary(verifier) do
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    %{"code_challenge" => challenge, "code_challenge_method" => "S256"}
  end

  defp pkce_params(_, _), do: %{}

  defp resource_params(%Provider{kind: "mcp"} = p) do
    case resource(p) do
      nil -> %{}
      r -> %{"resource" => r}
    end
  end

  defp resource_params(_), do: %{}

  @doc "The protected resource an `mcp` provider's token is for (RFC 8707)."
  def resource(%Provider{kind: "mcp", mcp_metadata: md, mcp_url: url}),
    do: md["resource"] || url

  def resource(_), do: nil

  @doc """
  Exchange the code from the callback for tokens: `{:ok, grant}`. The grant
  has no `refresh_token` when the provider issued none, no `expires_at` when
  it said nothing about expiry, and no `account_email` when the provider
  has no userinfo endpoint — the caller labels the account then.
  """
  @spec exchange_code(Provider.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, grant()} | {:error, term()}
  def exchange_code(%Provider{} = p, code, redirect_uri, verifier \\ nil)
      when is_binary(code) and is_binary(redirect_uri) do
    form =
      %{
        "code" => code,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code"
      }
      |> maybe_put("code_verifier", verifier)
      |> maybe_put("resource", resource(p))

    with {:ok, %{"access_token" => access} = body} when is_binary(access) <-
           token_request(p, form),
         :ok <- require_refresh_token(p, body),
         {:ok, label} <- account_label(p, access) do
      {:ok,
       %{
         refresh_token: refresh_token(body),
         access_token: access,
         expires_at: expires_at(body["expires_in"]),
         scopes: scopes(body["scope"], p.scopes),
         account_email: label
       }}
    else
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = err -> err
    end
  end

  # Google issues an hour-long access token and, on a repeat consent, no
  # refresh token unless the tenant removes the app first: a connection
  # without one would be dead in an hour, so a platform provider insists —
  # but only when the token expires at all. Slack's user tokens carry no
  # expiry and no refresh token unless the app opts in to rotation, and are
  # good until revoked. A tenant provider takes what it gets; a missing
  # refresh token there is the provider's design, and the connection goes
  # `expired` when the token does.
  defp require_refresh_token(%Provider{user_id: nil}, body) do
    expiring? = is_integer(body["expires_in"]) or is_binary(body["expires_in"])

    if is_binary(refresh_token(body)) or not expiring?,
      do: :ok,
      else: {:error, :no_refresh_token}
  end

  defp require_refresh_token(_p, _body), do: :ok

  @doc """
  A fresh access token for a refresh token: `{:ok, %{access_token,
  expires_at, refresh_token}}` (the last only when the provider rotated
  it), `{:error, :invalid_grant}` when the provider has forgotten the grant,
  or `{:error, reason}`.
  """
  @spec refresh(Provider.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(%Provider{} = p, refresh_token) when is_binary(refresh_token) do
    form =
      %{"refresh_token" => refresh_token, "grant_type" => "refresh_token"}
      |> maybe_put("resource", resource(p))

    case token_request(p, form) do
      {:ok, %{"access_token" => access} = body} when is_binary(access) ->
        {:ok,
         %{
           access_token: access,
           expires_at: expires_at(body["expires_in"]),
           refresh_token: refresh_token(body)
         }}

      {:ok, other} ->
        {:error, {:unexpected, other}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Tell the provider to forget the grant (RFC 7009). Best effort: an
  already-revoked token is a 400 there and `:ok` here, because the outcome
  is the same; a provider with no `revoke_url` is `:ok` at once.
  """
  @spec revoke(Provider.t(), String.t()) :: :ok | {:error, term()}
  def revoke(%Provider{revoke_url: nil}, _token), do: :ok
  def revoke(%Provider{revoke_url: ""}, _token), do: :ok

  def revoke(%Provider{} = p, token) when is_binary(token) do
    with :ok <- guard(p, p.revoke_url) do
      {form, opts} = client_auth(p, %{"token" => token})

      case Req.post(req(), [url: p.revoke_url, form: form] ++ opts) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: 400}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ── the token endpoint ─────────────────────────────────────────────────────

  defp token_request(p, form) do
    with :ok <- guard(p, p.token_url) do
      {form, opts} = client_auth(p, form)

      case Req.post(
             req(),
             [url: p.token_url, form: form, headers: [accept: "application/json"]] ++ opts
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case decode_token_body(body) do
            {:ok, decoded} ->
              # Reshaped before the error check: a nested success body has no
              # top-level access_token until the grant is lifted out.
              decoded = normalize_token_body(p, decoded)
              if error_body?(decoded), do: token_error(status, decoded), else: {:ok, decoded}

            {:error, _} = err ->
              err
          end

        {:ok, %{status: status, body: body}} when status in 400..499 ->
          token_error(status, body)

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A provider's token response, reshaped to the RFC 6749 top level where
  # the provider nests it under `token_body_nest` (Slack: `authed_user`).
  defp normalize_token_body(%Provider{token_body_nest: key}, body)
       when is_binary(key) and key != "" do
    case body do
      %{^key => %{"access_token" => _} = nested} ->
        Map.merge(body, Map.take(nested, ~w(access_token refresh_token expires_in scope)))

      _ ->
        body
    end
  end

  defp normalize_token_body(_p, body), do: body

  # Not every provider signals failure on the status line: Slack answers
  # HTTP 200 with `{"ok": false, "error": "invalid_refresh_token"}` and says
  # to inspect `ok`; GitHub answers 200 with `error=bad_refresh_token`. A
  # body that carries an error and no token is an error, whatever the status.
  defp error_body?(%{"access_token" => access}) when is_binary(access) and access != "", do: false
  defp error_body?(%{"ok" => ok}) when ok in [false, "false"], do: true
  defp error_body?(%{"error" => e}) when is_binary(e) and e != "", do: true
  defp error_body?(_), do: false

  defp token_error(status, body) do
    if invalid_grant?(body), do: {:error, :invalid_grant}, else: {:error, {:http, status, body}}
  end

  # GitHub answers a form-encoded body unless asked for JSON, and some
  # providers ignore the Accept header altogether.
  defp decode_token_body(body) when is_map(body), do: {:ok, body}

  defp decode_token_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:ok, URI.decode_query(body)}
    end
  end

  defp decode_token_body(other), do: {:error, {:unexpected, other}}

  # `invalid_grant` is the RFC 6749 shape; GitHub says `bad_refresh_token`
  # and Slack `invalid_refresh_token` / `token_revoked`. All mean the same:
  # the provider no longer honours this grant.
  defp invalid_grant?(%{"error" => e}) when is_binary(e),
    do: e in ~w(invalid_grant bad_refresh_token invalid_refresh_token token_revoked)

  defp invalid_grant?(body) when is_binary(body),
    do: String.contains?(body, "invalid_grant") or String.contains?(body, "bad_refresh_token")

  defp invalid_grant?(_), do: false

  defp client_auth(%Provider{token_endpoint_auth: "client_secret_basic"} = p, form),
    do: {form, [auth: {:basic, "#{p.client_id}:#{p.client_secret}"}]}

  defp client_auth(%Provider{token_endpoint_auth: "none"} = p, form),
    do: {Map.put(form, "client_id", p.client_id || ""), []}

  defp client_auth(p, form) do
    {Map.merge(form, %{"client_id" => p.client_id || "", "client_secret" => p.client_secret || ""}),
     []}
  end

  # ── the account label ──────────────────────────────────────────────────────

  defp account_label(%Provider{userinfo_url: url} = p, access)
       when is_binary(url) and url != "" do
    with :ok <- guard(p, url) do
      case Req.get(req(),
             url: url,
             auth: {:bearer, access},
             headers: [accept: "application/json"]
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          case dig(body, p.account_label_path || "email") do
            label when is_binary(label) and label != "" -> {:ok, label}
            number when is_integer(number) -> {:ok, Integer.to_string(number)}
            _ -> {:error, {:userinfo, :no_label, p.account_label_path}}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:userinfo, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp account_label(_p, _access), do: {:ok, nil}

  @doc false
  def dig(body, path) when is_map(body) and is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce_while(body, fn key, acc ->
      case acc do
        %{} = m -> {:cont, Map.get(m, key)}
        list when is_list(list) -> {:cont, index(list, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp index(list, key) do
    case Integer.parse(key) do
      {i, ""} -> Enum.at(list, i)
      _ -> nil
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Platform provider URLs are ours; a tenant's are checked on every fetch.
  defp guard(%Provider{user_id: nil}, _url), do: :ok

  defp guard(_p, url) do
    case UrlGuard.check(url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_url, reason}}
    end
  end

  defp refresh_token(%{"refresh_token" => r}) when is_binary(r) and r != "", do: r
  defp refresh_token(_), do: nil

  defp scopes(scope, _default) when is_binary(scope) and scope != "",
    do: String.split(scope, ~r/[ ,]+/, trim: true)

  defp scopes(_, default), do: default

  defp expires_at(ttl) when is_integer(ttl) and ttl > 0,
    do: DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.truncate(:second)

  defp expires_at(ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} -> expires_at(n)
      _ -> nil
    end
  end

  defp expires_at(_), do: nil

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  @doc false
  def req do
    Req.new(
      [
        receive_timeout: Application.get_env(:fountain, :connections_timeout_ms, 15_000),
        retry: false,
        redirect: false
      ] ++ Application.get_env(:fountain, :connections_req_options, [])
    )
  end
end
