defmodule Fountain.Connections.OAuth do
  @moduledoc """
  Every request a connection makes to a remote MCP server's authorization
  server (ADR 0085). Nothing here keeps state or touches the database:
  `Fountain.Connections` holds the rows, the lease and the PKCE verifier.

    * `discover/1`: the MCP authorization spec's discovery. The server URL
      is requested without a token and `resource_metadata` is read from the
      `401`'s `WWW-Authenticate`; failing that the path-specific
      `/.well-known/oauth-protected-resource/<path>`, then the origin's. The
      protected-resource metadata (RFC 9728) names the authorization server,
      whose RFC 8414 metadata is read, with OpenID Connect discovery as the
      fallback.
    * `register/3`: a client ID metadata document, RFC 7591 dynamic
      registration, or a client the user pasted.
    * `authorize_url/1`, `exchange_code/3`, `refresh/2`, `revoke/2`: the
      authorization-code flow with PKCE `S256` and the RFC 8707 `resource`
      on both the authorize and the token requests.

  Every URL goes through `Fountain.Connections.UrlGuard` immediately before
  it is fetched, and the connection is made to the address the guard
  resolved, with the hostname kept for SNI and the certificate check. No
  redirect is followed and no response body over 512 KiB is read.

  Folded in from the archived `managoat_mcp_auth` 0.2.0 (ADR 0085 decision
  11, #2746), trimmed to what the ADR uses.

  Errors carry a status and an OAuth error code, never a body: a token
  endpoint's body can hold tokens, so no caller ever holds one to log.
  `:connections_req_options` is merged into every request so a test can
  stand in for the network (`plug: {Req.Test, ...}`).
  """

  alias Fountain.Connections.UrlGuard

  @max_body 512 * 1024
  @terminal ~w(invalid_grant)
  # Protocol versions are dated; this is the one discovery's probe announces.
  @probe_protocol "2025-06-18"

  @type metadata :: %{
          resource: String.t(),
          authorization_server: String.t(),
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          registration_endpoint: String.t() | nil,
          revocation_endpoint: String.t() | nil,
          scopes: [String.t()],
          token_endpoint_auth_methods: [String.t()],
          client_id_metadata_document_supported: boolean(),
          iss_parameter_supported: boolean()
        }

  @type client :: %{
          registration: String.t(),
          client_id: String.t(),
          client_secret: String.t() | nil,
          token_endpoint_auth_method: String.t()
        }

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          scope: String.t() | nil
        }

  @typedoc "What a token, refresh or revoke request needs to know about the connection."
  @type endpoint :: %{
          required(:token_endpoint) => String.t(),
          required(:client_id) => String.t(),
          required(:client_secret) => String.t() | nil,
          required(:token_endpoint_auth_method) => String.t(),
          required(:resource) => String.t(),
          optional(:revocation_endpoint) => String.t() | nil
        }

  # ── discovery ──────────────────────────────────────────────────────────────

  @doc """
  The authorization metadata for an MCP server URL. `{:error, reason}` names
  the step that failed: `{:unsafe_url, url, reason}`, `{:mcp_server, why}`,
  `:no_resource_metadata`, `:resource_mismatch`, `:no_authorization_server`,
  `:no_authorization_server_metadata`, `:issuer_mismatch`,
  `:incomplete_authorization_server_metadata` or `:pkce_s256_unsupported`.
  """
  @spec discover(String.t()) :: {:ok, metadata()} | {:error, term()}
  def discover(server_url) when is_binary(server_url) do
    with {:ok, prm} <- protected_resource_metadata(server_url),
         {:ok, resource} <- resource(prm, server_url),
         {:ok, as_id} <- authorization_server(prm),
         {:ok, as} <- authorization_server_metadata(as_id),
         :ok <- check_endpoints(as),
         :ok <- check_pkce(as) do
      {:ok,
       %{
         resource: resource,
         authorization_server: as_id,
         issuer: as["issuer"],
         authorization_endpoint: as["authorization_endpoint"],
         token_endpoint: as["token_endpoint"],
         registration_endpoint: string(as["registration_endpoint"]),
         revocation_endpoint: string(as["revocation_endpoint"]),
         scopes: scopes(prm, as),
         token_endpoint_auth_methods: strings(as["token_endpoint_auth_methods_supported"]),
         client_id_metadata_document_supported:
           as["client_id_metadata_document_supported"] == true,
         iss_parameter_supported: as["authorization_response_iss_parameter_supported"] == true
       }}
    end
  end

  defp protected_resource_metadata(server_url) do
    case probe(server_url) do
      {:ok, url} when is_binary(url) ->
        fetch_json(url)

      {:ok, nil} ->
        server_url
        |> well_known_resource()
        |> Enum.reduce_while({:error, :no_resource_metadata}, fn url, acc ->
          case fetch_json(url) do
            {:ok, _} = ok -> {:halt, ok}
            {:error, {:unsafe_url, _, _}} = unsafe -> {:halt, unsafe}
            _ -> {:cont, acc}
          end
        end)

      {:error, _} = error ->
        error
    end
  end

  # An unauthenticated MCP request. A protected server answers 401 and, if it
  # follows RFC 9728, names its metadata in the challenge.
  defp probe(server_url) do
    body = %{
      jsonrpc: "2.0",
      id: 0,
      method: "initialize",
      params: %{
        protocolVersion: @probe_protocol,
        capabilities: %{},
        clientInfo: %{name: "managoat", version: version()}
      }
    }

    case request(:post, server_url,
           json: body,
           headers: [{"accept", "application/json, text/event-stream"}]
         ) do
      {:ok, %{status: 401, headers: headers}} ->
        {:ok, headers |> Map.get("www-authenticate", []) |> resource_metadata_param()}

      {:ok, _other_status} ->
        {:ok, nil}

      {:error, {:unsafe_url, _, _}} = unsafe ->
        unsafe

      {:error, reason} ->
        {:error, {:mcp_server, reason}}
    end
  end

  @doc """
  The `resource_metadata` parameter of a `WWW-Authenticate` challenge (RFC
  9728 §5.1), or nil. Takes the header's values as a list or one string;
  the value may be a quoted string, with backslash escapes, or a token.

      iex> Fountain.Connections.OAuth.resource_metadata_param(
      ...>   ~s(Bearer realm="OAuth", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="read write")
      ...> )
      "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
  """
  @spec resource_metadata_param([String.t()] | String.t()) :: String.t() | nil
  def resource_metadata_param(values) when is_list(values),
    do: Enum.find_value(values, &resource_metadata_param/1)

  def resource_metadata_param(value) when is_binary(value) do
    ~r/(?:^|[\s,])resource_metadata\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,"]+))/i
    |> Regex.run(value)
    |> case do
      [_, quoted] -> Regex.replace(~r/\\(.)/, quoted, "\\1")
      [_, "", token] -> token
      _ -> nil
    end
  end

  def resource_metadata_param(_), do: nil

  # RFC 9728 §3.1: the well-known name inserted between the host and the
  # path, then the origin's own document.
  defp well_known_resource(server_url) do
    uri = URI.parse(server_url)
    path = String.trim_trailing(uri.path || "", "/")

    ["/.well-known/oauth-protected-resource" <> path, "/.well-known/oauth-protected-resource"]
    |> Enum.uniq()
    |> Enum.map(&at_path(uri, &1))
  end

  # The resource the metadata names, which must be on the server's own
  # origin: a document that claimed another server's resource would have us
  # ask for tokens bound to it.
  defp resource(%{"resource" => resource}, server_url) when is_binary(resource) do
    if origin(resource) == origin(server_url),
      do: {:ok, resource},
      else: {:error, :resource_mismatch}
  end

  defp resource(_prm, server_url), do: {:ok, server_url}

  defp authorization_server(%{"authorization_servers" => [as | _]}) when is_binary(as),
    do: {:ok, as}

  defp authorization_server(_), do: {:error, :no_authorization_server}

  # RFC 8414 with the well-known name inserted before the issuer's path, then
  # OpenID Connect discovery both ways, as the MCP spec orders them. The
  # document's `issuer` must be the one asked about, ignoring one trailing
  # slash: Google writes it with one in one place and without in another.
  defp authorization_server_metadata(as_id) do
    uri = URI.parse(as_id)
    path = String.trim_trailing(uri.path || "", "/")

    candidates =
      [
        "/.well-known/oauth-authorization-server" <> path,
        "/.well-known/openid-configuration" <> path,
        path <> "/.well-known/openid-configuration"
      ]
      |> Enum.uniq()
      |> Enum.map(&at_path(uri, &1))

    Enum.reduce_while(candidates, {:error, :no_authorization_server_metadata}, fn url, acc ->
      case fetch_json(url) do
        {:ok, %{"issuer" => issuer} = md} when is_binary(issuer) ->
          if same_issuer?(issuer, as_id),
            do: {:halt, {:ok, md}},
            else: {:halt, {:error, :issuer_mismatch}}

        {:error, {:unsafe_url, _, _}} = unsafe ->
          {:halt, unsafe}

        _ ->
          {:cont, acc}
      end
    end)
  end

  @doc "Whether two issuer identifiers are the same, ignoring one trailing slash."
  @spec same_issuer?(term(), term()) :: boolean()
  def same_issuer?(a, b) when is_binary(a) and is_binary(b),
    do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")

  def same_issuer?(_, _), do: false

  # Each endpoint is checked on its own: an authorization server's endpoints
  # need not share its origin (Google's token and JWKS hosts differ).
  defp check_endpoints(%{"authorization_endpoint" => a, "token_endpoint" => t} = as)
       when is_binary(a) and is_binary(t) do
    [a, t, as["registration_endpoint"], as["revocation_endpoint"], as["jwks_uri"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce_while(:ok, fn url, :ok ->
      case guard(url) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_endpoints(_), do: {:error, :incomplete_authorization_server_metadata}

  # The MCP spec: a client must refuse to proceed unless S256 is advertised.
  defp check_pkce(as) do
    if "S256" in strings(as["code_challenge_methods_supported"]),
      do: :ok,
      else: {:error, :pkce_s256_unsupported}
  end

  # The resource's own scopes first (what the server accepts), else the
  # authorization server's.
  defp scopes(prm, as) do
    case strings(prm["scopes_supported"]) do
      [] -> strings(as["scopes_supported"])
      scopes -> scopes
    end
  end

  # ── registration ───────────────────────────────────────────────────────────

  @doc """
  A client for the connection.

    * `:client_id_metadata_document`: the URL of Managoat's client metadata
      (`opts[:client_id_metadata_url]`) is the client id. Only when the
      server advertises support.
    * `:dynamic`: RFC 7591 registration at the server's
      `registration_endpoint`, with `opts[:redirect_uri]`. A public client
      (PKCE alone) where the server allows one.
    * `{:pasted, client_id, client_secret}`: a client the user registered
      with the provider. A secret makes it confidential.
  """
  @spec register(metadata(), atom() | tuple(), keyword()) :: {:ok, client()} | {:error, term()}
  def register(meta, mode, opts \\ [])

  def register(%{client_id_metadata_document_supported: true}, :client_id_metadata_document, opts) do
    {:ok,
     %{
       registration: "client_id_metadata_document",
       client_id: Keyword.fetch!(opts, :client_id_metadata_url),
       client_secret: nil,
       token_endpoint_auth_method: "none"
     }}
  end

  def register(_meta, :client_id_metadata_document, _opts), do: {:error, :not_supported}

  def register(%{registration_endpoint: endpoint} = meta, :dynamic, opts)
      when is_binary(endpoint) do
    method = preferred_auth(meta.token_endpoint_auth_methods)

    body =
      %{
        "client_name" => "Managoat",
        "client_uri" => Keyword.fetch!(opts, :client_uri),
        "redirect_uris" => [Keyword.fetch!(opts, :redirect_uri)],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => method
      }
      |> then(fn b ->
        if meta.scopes == [], do: b, else: Map.put(b, "scope", Enum.join(meta.scopes, " "))
      end)

    case request(:post, endpoint, json: body) do
      {:ok, %{status: status, body: %{"client_id" => id} = resp}}
      when status in 200..299 and is_binary(id) and id != "" ->
        secret = string(resp["client_secret"])

        {:ok,
         %{
           registration: "dynamic",
           client_id: id,
           client_secret: secret,
           token_endpoint_auth_method: issued_auth(resp["token_endpoint_auth_method"], secret)
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:registration, status, error_code(body)}}

      {:error, _} = error ->
        error
    end
  end

  def register(_meta, :dynamic, _opts), do: {:error, :not_supported}

  def register(meta, {:pasted, client_id, secret}, _opts)
      when is_binary(client_id) and client_id != "" do
    secret = string(secret)

    method =
      cond do
        is_nil(secret) -> "none"
        "client_secret_basic" in meta.token_endpoint_auth_methods -> "client_secret_basic"
        "client_secret_post" in meta.token_endpoint_auth_methods -> "client_secret_post"
        meta.token_endpoint_auth_methods == [] -> "client_secret_basic"
        true -> hd(meta.token_endpoint_auth_methods)
      end

    {:ok,
     %{
       registration: "pasted",
       client_id: client_id,
       client_secret: secret,
       token_endpoint_auth_method: method
     }}
  end

  def register(_meta, {:pasted, _, _}, _opts), do: {:error, :no_client_id}

  defp preferred_auth(supported) do
    cond do
      supported == [] or "none" in supported -> "none"
      "client_secret_basic" in supported -> "client_secret_basic"
      true -> "client_secret_post"
    end
  end

  defp issued_auth(method, _secret)
       when method in ~w(none client_secret_basic client_secret_post),
       do: method

  defp issued_auth(_method, nil), do: "none"
  defp issued_auth(_method, _secret), do: "client_secret_basic"

  # ── the authorization-code flow ────────────────────────────────────────────

  @doc "A PKCE code verifier: 64 unreserved characters (RFC 7636)."
  @spec code_verifier() :: String.t()
  def code_verifier, do: Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

  @doc "The `S256` challenge for a verifier."
  @spec code_challenge(String.t()) :: String.t()
  def code_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  @reserved_params ~w(client_id redirect_uri response_type state code_challenge code_challenge_method resource)

  @doc """
  Where to send the user. `params`: `:authorization_endpoint`,
  `:client_id`, `:redirect_uri`, `:state`, `:verifier`, `:resource`,
  `:scopes` and `:extra`, the user's own parameters (Google's
  `access_type=offline`). An extra parameter cannot replace one the flow
  depends on.
  """
  @spec authorize_url(map()) :: String.t()
  def authorize_url(params) do
    extra = Map.drop(params[:extra] || %{}, @reserved_params)

    scope =
      case params[:scopes] || [] do
        [] -> %{}
        scopes -> %{"scope" => Enum.join(scopes, " ")}
      end

    query =
      extra
      |> Map.merge(scope)
      |> Map.merge(%{
        "response_type" => "code",
        "client_id" => params.client_id,
        "redirect_uri" => params.redirect_uri,
        "state" => params.state,
        "code_challenge" => code_challenge(params.verifier),
        "code_challenge_method" => "S256",
        "resource" => params.resource
      })
      |> URI.encode_query()

    endpoint = params.authorization_endpoint
    endpoint <> if(String.contains?(endpoint, "?"), do: "&", else: "?") <> query
  end

  @doc "Exchange the callback's code, with the verifier and the redirect URI it was issued for."
  @spec exchange_code(endpoint(), String.t(), keyword()) :: {:ok, tokens()} | {:error, term()}
  def exchange_code(endpoint, code, opts) when is_binary(code) do
    token_request(endpoint, %{
      "grant_type" => "authorization_code",
      "code" => code,
      "code_verifier" => Keyword.fetch!(opts, :verifier),
      "redirect_uri" => Keyword.fetch!(opts, :redirect_uri),
      "resource" => endpoint.resource
    })
  end

  @doc """
  A new access token for a refresh token. `{:error, {:terminal, code}}`
  when the server refused the grant for good; any other error is transient.
  A response without a refresh token keeps the old one (`refresh_token: nil`).
  """
  @spec refresh(endpoint(), String.t()) :: {:ok, tokens()} | {:error, term()}
  def refresh(endpoint, refresh_token) when is_binary(refresh_token) do
    token_request(endpoint, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "resource" => endpoint.resource
    })
  end

  @doc """
  Revoke a token at the server (RFC 7009). `:ok` on a 2xx;
  `{:error, :no_revocation_endpoint}` when the server has none;
  `{:error, {:revoke, status, code}}` otherwise.
  """
  @spec revoke(endpoint(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke(endpoint, token, hint \\ "refresh_token")

  def revoke(%{revocation_endpoint: url} = endpoint, token, hint)
      when is_binary(url) and is_binary(token) do
    {form, auth} = client_auth(endpoint, %{"token" => token, "token_type_hint" => hint})

    case request(:post, url, [form: form] ++ auth) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:revoke, status, error_code(body)}}
      {:error, _} = error -> error
    end
  end

  def revoke(_endpoint, _token, _hint), do: {:error, :no_revocation_endpoint}

  defp token_request(endpoint, form) do
    {form, auth} = client_auth(endpoint, form)

    case request(:post, endpoint.token_endpoint, [form: form] ++ auth) do
      {:ok, %{status: status, body: %{"access_token" => access} = body}}
      when status in 200..299 and is_binary(access) and access != "" ->
        {:ok,
         %{
           access_token: access,
           refresh_token: string(body["refresh_token"]),
           expires_at: expires_at(body["expires_in"]),
           scope: string(body["scope"])
         }}

      {:ok, %{status: status, body: body}} ->
        case error_code(body) do
          code when code in @terminal -> {:error, {:terminal, code}}
          code -> {:error, {:token, status, code}}
        end

      {:error, _} = error ->
        error
    end
  end

  # RFC 6749 §2.3.1: Basic credentials are form-encoded before base64.
  defp client_auth(%{token_endpoint_auth_method: "client_secret_basic"} = e, form) do
    creds = www_form(e.client_id) <> ":" <> www_form(e.client_secret || "")
    {form, [auth: {:basic, creds}]}
  end

  defp client_auth(%{token_endpoint_auth_method: "client_secret_post"} = e, form),
    do: {Map.merge(form, %{"client_id" => e.client_id, "client_secret" => e.client_secret}), []}

  defp client_auth(e, form), do: {Map.put(form, "client_id", e.client_id), []}

  defp www_form(value), do: URI.encode_www_form(value)

  # ── HTTP ───────────────────────────────────────────────────────────────────

  defp fetch_json(url) do
    case request(:get, url, []) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:metadata, status}}
      {:error, _} = error -> error
    end
  end

  # Guard, then connect to the address the guard resolved: the URL carries
  # the IP, and Mint's `:hostname` keeps the name for SNI, the certificate
  # check and the Host header. One resolution, so no gap between the check
  # and the fetch for DNS to change in.
  defp request(method, url, opts) do
    with {:ok, target} <- guard(url) do
      headers = [
        {"host", host_header(target.uri)},
        {"user-agent", "managoat/" <> version()}
        | Keyword.get(opts, :headers, [{"accept", "application/json"}])
      ]

      [
        method: method,
        url: pinned(target),
        headers: headers,
        connect_options: [hostname: target.host, protocols: [:http1], timeout: 5_000],
        receive_timeout: 10_000,
        redirect: false,
        retry: false,
        compressed: false,
        decode_body: false,
        into: &capped/2
      ]
      |> Keyword.merge(Keyword.take(opts, [:json, :form, :auth]))
      |> Keyword.merge(Application.get_env(:fountain, :connections_req_options, []))
      |> Req.request()
      |> case do
        {:ok, %Req.Response{private: %{too_large: true}}} ->
          {:error, :response_too_large}

        {:ok, %Req.Response{} = resp} ->
          {:ok, %{status: resp.status, headers: resp.headers, body: decoded(resp)}}

        {:error, e} ->
          {:error, {:transport, Exception.message(e)}}
      end
    end
  end

  defp capped({:data, data}, {req, resp}) do
    body = resp.body <> data

    if byte_size(body) > @max_body,
      do: {:halt, {req, %{resp | body: "", private: Map.put(resp.private, :too_large, true)}}},
      else: {:cont, {req, %{resp | body: body}}}
  end

  defp guard(url) do
    case UrlGuard.check(url) do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, {:unsafe_url, url, reason}}
    end
  end

  defp pinned(%{uri: uri, address: address}) do
    ip = address |> :inet.ntoa() |> to_string()
    ip = if tuple_size(address) == 8, do: "[" <> ip <> "]", else: ip
    port = if uri.port && uri.port != 443, do: ":#{uri.port}", else: ""
    query = if uri.query, do: "?" <> uri.query, else: ""
    "https://" <> ip <> port <> (uri.path || "/") <> query
  end

  defp host_header(%URI{host: host, port: port}) when port in [nil, 443], do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  # JSON when it parses as an object, the bytes otherwise; a token
  # endpoint's form-encoded answer is decoded too.
  defp decoded(%Req.Response{body: body} = resp) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        map

      _ ->
        if form?(resp), do: URI.decode_query(body), else: body
    end
  end

  defp decoded(%Req.Response{body: body}), do: body

  defp form?(resp) do
    resp
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.contains?(&1, "x-www-form-urlencoded"))
  end

  @doc false
  def error_code(%{"error" => code}) when is_binary(code), do: code
  def error_code(body) when is_map(body), do: "unknown"
  def error_code(_body), do: "unreadable"

  defp at_path(%URI{} = uri, path),
    do: URI.to_string(%URI{uri | path: path, query: nil, fragment: nil})

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h, port: p} when is_binary(h) -> {s, String.downcase(h), p}
      _ -> nil
    end
  end

  defp expires_at(ttl) when is_integer(ttl) and ttl > 0,
    do: DateTime.utc_now() |> DateTime.add(ttl, :second) |> DateTime.truncate(:second)

  defp expires_at(ttl) when is_binary(ttl) do
    case Integer.parse(ttl) do
      {n, ""} -> expires_at(n)
      _ -> nil
    end
  end

  defp expires_at(_), do: nil

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_), do: []

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp version, do: to_string(Application.spec(:fountain, :vsn) || "0")
end
