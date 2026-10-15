defmodule Fountain.Connections.TestResolver do
  @moduledoc """
  Name resolution for the suite's connections (`:connections_resolver`):
  every name is public unless its first label says otherwise.
  """

  @public {93, 184, 216, 34}

  def resolve("private." <> _), do: [{10, 0, 0, 7}]
  def resolve("loopback." <> _), do: [{127, 0, 0, 1}]
  def resolve("metadata." <> _), do: [{169, 254, 169, 254}]
  def resolve("cgnat." <> _), do: [{100, 64, 0, 1}]
  def resolve("v6loop." <> _), do: [{0, 0, 0, 0, 0, 0, 0, 1}]
  def resolve("mixed." <> _), do: [@public, {192, 168, 1, 1}]
  def resolve("nowhere." <> _), do: []
  def resolve("v6." <> _), do: [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}]
  def resolve(_host), do: [@public]
end

defmodule Fountain.Connections.FakeProvider do
  @moduledoc """
  A remote MCP server and its authorization server, as a plug for
  `Req.Test.stub(Fountain.Connections.OAuth, ...)`. Routed on the Host
  header, which `Fountain.Connections.OAuth` sets because it connects to the
  resolved address.

  The server is `https://mcp.example.com/mcp`, the authorization server
  `https://auth.example.com`. `opts` turn features on and off:
  `:cimd` (default true), `:registration` (true), `:revocation` (true),
  `:iss` (false), `:challenge` (true: the 401 names the metadata),
  `:refresh` (true: tokens come with a refresh token), `:expires_in` (3600),
  `:refresh_error` (nil, or an OAuth error code the token endpoint answers
  a refresh with). Every request is sent to `opts[:test]` as
  `{:provider, method, host, path, params}`.
  """

  import Plug.Conn

  @server "https://mcp.example.com/mcp"
  @issuer "https://auth.example.com"

  def server_url, do: @server
  def issuer, do: @issuer

  def stub(opts \\ []) do
    opts = Keyword.put_new(opts, :test, self())
    Req.Test.stub(Fountain.Connections.OAuth, &call(&1, opts))
    opts
  end

  def call(conn, opts) do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, body, conn} = read_body(conn)

    params =
      case get_req_header(conn, "content-type") do
        ["application/x-www-form-urlencoded" <> _] -> URI.decode_query(body)
        ["application/json" <> _] -> Jason.decode!(body)
        _ -> conn.query_params
      end

    [host] = get_req_header(conn, "host")
    send(opts[:test], {:provider, conn.method, host, conn.request_path, params, conn})
    route(conn, conn.method, host, conn.request_path, params, opts)
  end

  defp route(conn, "POST", "mcp.example.com", "/mcp", _params, opts) do
    if Keyword.get(opts, :challenge, true) do
      conn
      |> put_resp_header(
        "www-authenticate",
        ~s(Bearer realm="OAuth", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="read write")
      )
      |> send_resp(401, "")
    else
      send_resp(conn, 401, "")
    end
  end

  defp route(conn, "GET", "mcp.example.com", "/.well-known/oauth-protected-resource/mcp", _, _),
    do:
      json(conn, 200, %{
        "resource" => @server,
        "authorization_servers" => [@issuer],
        "scopes_supported" => ["read", "write"]
      })

  defp route(conn, "GET", "auth.example.com", "/.well-known/oauth-authorization-server", _, opts) do
    md =
      %{
        "issuer" => @issuer <> "/",
        "authorization_endpoint" => @issuer <> "/authorize",
        "token_endpoint" => "https://token.example.com/token",
        "code_challenge_methods_supported" => ["S256"],
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "token_endpoint_auth_methods_supported" => ["none", "client_secret_basic"],
        "client_id_metadata_document_supported" => Keyword.get(opts, :cimd, true),
        "authorization_response_iss_parameter_supported" => Keyword.get(opts, :iss, false)
      }
      |> put_if(
        Keyword.get(opts, :registration, true),
        "registration_endpoint",
        @issuer <> "/register"
      )
      |> put_if(Keyword.get(opts, :revocation, true), "revocation_endpoint", @issuer <> "/revoke")

    json(conn, 200, md)
  end

  defp route(conn, "POST", "auth.example.com", "/register", params, _opts) do
    json(conn, 201, %{
      "client_id" => "dyn-client",
      "redirect_uris" => params["redirect_uris"],
      "token_endpoint_auth_method" => "none"
    })
  end

  defp route(conn, "POST", "token.example.com", "/token", params, opts) do
    case params["grant_type"] do
      "authorization_code" ->
        if params["code"] == "good-code" and is_binary(params["code_verifier"]),
          do: json(conn, 200, tokens("access-1", "refresh-1", opts)),
          else: json(conn, 400, %{"error" => "invalid_grant"})

      "refresh_token" ->
        case opts[:refresh_error] do
          nil ->
            n = System.unique_integer([:positive])
            json(conn, 200, tokens("access-r#{n}", "refresh-r#{n}", opts))

          code ->
            json(conn, 400, %{"error" => code})
        end
    end
  end

  defp route(conn, "POST", "auth.example.com", "/revoke", _params, _opts),
    do: send_resp(conn, 200, "")

  defp route(conn, _method, _host, _path, _params, _opts), do: send_resp(conn, 404, "")

  defp tokens(access, refresh, opts) do
    %{"access_token" => access, "token_type" => "Bearer"}
    |> put_if(Keyword.get(opts, :refresh, true), "refresh_token", refresh)
    |> put_if(opts[:expires_in] != false, "expires_in", Keyword.get(opts, :expires_in, 3600))
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _, _key, _value), do: map

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
