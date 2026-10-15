defmodule Fountain.Connections.OAuthTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Fountain.Connections.{FakeProvider, OAuth}

  @linear ~s(Bearer realm="OAuth", resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write")

  describe "resource_metadata_param/1" do
    test "reads Linear's real challenge" do
      assert OAuth.resource_metadata_param(@linear) ==
               "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp"

      assert OAuth.resource_metadata_param(["Basic realm=\"x\"", @linear]) ==
               "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp"
    end

    test "a token value, escapes, case, and look-alike parameters" do
      assert OAuth.resource_metadata_param("Bearer resource_metadata=https://a.example/rm") ==
               "https://a.example/rm"

      assert OAuth.resource_metadata_param(~s(Bearer Resource_Metadata="https://a.example/r\\"m")) ==
               ~s(https://a.example/r"m)

      assert OAuth.resource_metadata_param(~s(Bearer xresource_metadata="https://evil.example")) ==
               nil

      assert OAuth.resource_metadata_param(~s(Bearer realm="OAuth")) == nil
      assert OAuth.resource_metadata_param([]) == nil
    end
  end

  describe "discover/1" do
    test "follows the challenge to the resource and its authorization server" do
      FakeProvider.stub()

      assert {:ok, meta} = OAuth.discover(FakeProvider.server_url())
      assert meta.resource == "https://mcp.example.com/mcp"
      assert meta.authorization_server == "https://auth.example.com"
      # The metadata's issuer has a trailing slash; the identifier does not.
      assert meta.issuer == "https://auth.example.com/"
      assert meta.authorization_endpoint == "https://auth.example.com/authorize"
      # On another host than the issuer, as Google's is.
      assert meta.token_endpoint == "https://token.example.com/token"
      assert meta.registration_endpoint == "https://auth.example.com/register"
      assert meta.revocation_endpoint == "https://auth.example.com/revoke"
      assert meta.scopes == ["read", "write"]
      assert meta.client_id_metadata_document_supported
      refute meta.iss_parameter_supported
    end

    test "connects to the resolved address and names the host in the Host header" do
      FakeProvider.stub()
      {:ok, _} = OAuth.discover(FakeProvider.server_url())

      assert_received {:provider, "POST", "mcp.example.com", "/mcp", _, conn}
      assert conn.host == "93.184.216.34"
      assert conn.scheme == :https
      assert get_req_header(conn, "authorization") == []
    end

    test "without a challenge, the well-known path is tried" do
      FakeProvider.stub(challenge: false)

      assert {:ok, %{resource: "https://mcp.example.com/mcp"}} =
               OAuth.discover(FakeProvider.server_url())

      assert_received {:provider, "GET", "mcp.example.com",
                       "/.well-known/oauth-protected-resource/mcp", _, _}
    end

    test "refuses a challenge that points at a private address" do
      Req.Test.stub(OAuth, fn conn ->
        conn
        |> put_resp_header(
          "www-authenticate",
          ~s(Bearer resource_metadata="https://metadata.example.com/latest")
        )
        |> send_resp(401, "")
      end)

      assert {:error, {:unsafe_url, "https://metadata.example.com/latest", :private_address}} =
               OAuth.discover("https://mcp.example.com/mcp")
    end

    test "refuses metadata whose token endpoint is private" do
      stub_metadata(%{"token_endpoint" => "https://private.example.com/token"})

      assert {:error, {:unsafe_url, "https://private.example.com/token", :private_address}} =
               OAuth.discover("https://mcp.example.com/mcp")
    end

    test "refuses an authorization server whose issuer is another" do
      stub_metadata(%{"issuer" => "https://other.example.com"})
      assert {:error, :issuer_mismatch} = OAuth.discover("https://mcp.example.com/mcp")
    end

    test "refuses a server without S256" do
      stub_metadata(%{"code_challenge_methods_supported" => ["plain"]})
      assert {:error, :pkce_s256_unsupported} = OAuth.discover("https://mcp.example.com/mcp")
    end

    test "refuses a resource on another origin" do
      Req.Test.stub(OAuth, fn conn ->
        case conn.request_path do
          "/mcp" ->
            send_resp(conn, 401, "")

          "/.well-known/oauth-protected-resource/mcp" ->
            json(conn, %{
              "resource" => "https://other.example.com/mcp",
              "authorization_servers" => ["https://auth.example.com"]
            })

          _ ->
            send_resp(conn, 404, "")
        end
      end)

      assert {:error, :resource_mismatch} = OAuth.discover("https://mcp.example.com/mcp")
    end

    test "never follows a redirect" do
      Req.Test.stub(OAuth, fn conn ->
        case get_req_header(conn, "host") do
          ["mcp.example.com"] ->
            conn
            |> put_resp_header("location", "https://elsewhere.example.com/")
            |> send_resp(302, "")

          [host] ->
            send(self(), {:followed, host})
            send_resp(conn, 200, "{}")
        end
      end)

      assert {:error, :no_resource_metadata} = OAuth.discover("https://mcp.example.com/mcp")
      refute_received {:followed, _}
    end

    test "caps a response body" do
      Req.Test.stub(OAuth, fn conn ->
        case conn.request_path do
          "/mcp" -> send_resp(conn, 401, "")
          _ -> json(conn, %{"pad" => String.duplicate("x", 600 * 1024)})
        end
      end)

      assert {:error, :no_resource_metadata} = OAuth.discover("https://mcp.example.com/mcp")
    end

    test "refuses an IP literal before any request" do
      assert {:error, {:unsafe_url, _, :ip_literal}} = OAuth.discover("https://8.8.8.8/mcp")
    end
  end

  describe "register/3" do
    setup do
      FakeProvider.stub()
      {:ok, meta} = OAuth.discover(FakeProvider.server_url())
      %{meta: meta}
    end

    test "a client ID metadata document is a URL as the client id", %{meta: meta} do
      assert {:ok,
              %{
                registration: "client_id_metadata_document",
                client_id: "https://managoat.example/connections/client.json",
                client_secret: nil,
                token_endpoint_auth_method: "none"
              }} =
               OAuth.register(meta, :client_id_metadata_document,
                 client_id_metadata_url: "https://managoat.example/connections/client.json"
               )

      assert {:error, :not_supported} =
               OAuth.register(
                 %{meta | client_id_metadata_document_supported: false},
                 :client_id_metadata_document,
                 client_id_metadata_url: "x"
               )
    end

    test "dynamic registration asks for a public client with the redirect URI", %{meta: meta} do
      assert {:ok,
              %{
                registration: "dynamic",
                client_id: "dyn-client",
                token_endpoint_auth_method: "none"
              }} =
               OAuth.register(meta, :dynamic,
                 redirect_uri: "https://managoat.example/connections/callback",
                 client_uri: "https://managoat.example"
               )

      assert_received {:provider, "POST", "auth.example.com", "/register", body, _}
      assert body["redirect_uris"] == ["https://managoat.example/connections/callback"]
      assert body["token_endpoint_auth_method"] == "none"
      assert body["scope"] == "read write"
    end

    test "a pasted client with a secret is confidential", %{meta: meta} do
      assert {:ok,
              %{
                registration: "pasted",
                client_secret: "s",
                token_endpoint_auth_method: "client_secret_basic"
              }} =
               OAuth.register(meta, {:pasted, "id", "s"})

      assert {:ok, %{token_endpoint_auth_method: "none"}} =
               OAuth.register(meta, {:pasted, "id", nil})

      assert {:error, :no_client_id} = OAuth.register(meta, {:pasted, "", nil})
    end
  end

  describe "the code flow" do
    @endpoint %{
      token_endpoint: "https://token.example.com/token",
      revocation_endpoint: "https://auth.example.com/revoke",
      client_id: "cid",
      client_secret: "se:cret",
      token_endpoint_auth_method: "client_secret_basic",
      resource: "https://mcp.example.com/mcp"
    }

    test "the authorize URL carries PKCE S256, the resource and state; extras cannot override them" do
      url =
        OAuth.authorize_url(%{
          authorization_endpoint: "https://auth.example.com/authorize?tenant=x",
          client_id: "cid",
          redirect_uri: "https://managoat.example/connections/callback",
          state: "st",
          verifier: "verifier",
          resource: "https://mcp.example.com/mcp",
          scopes: ["read"],
          extra: %{"access_type" => "offline", "client_id" => "evil", "resource" => "evil"}
        })

      %URI{query: query} = URI.parse(url)
      q = URI.decode_query(query)
      assert q["tenant"] == "x"
      assert q["client_id"] == "cid"
      assert q["resource"] == "https://mcp.example.com/mcp"
      assert q["code_challenge_method"] == "S256"
      assert q["code_challenge"] == OAuth.code_challenge("verifier")
      assert q["state"] == "st"
      assert q["scope"] == "read"
      assert q["access_type"] == "offline"
      assert q["response_type"] == "code"
    end

    test "exchange sends the verifier, the resource and Basic client credentials" do
      FakeProvider.stub()

      assert {:ok,
              %{access_token: "access-1", refresh_token: "refresh-1", expires_at: %DateTime{}}} =
               OAuth.exchange_code(@endpoint, "good-code",
                 verifier: "v",
                 redirect_uri: "https://managoat.example/connections/callback"
               )

      assert_received {:provider, "POST", "token.example.com", "/token", form, conn}
      assert form["code_verifier"] == "v"
      assert form["resource"] == "https://mcp.example.com/mcp"
      refute Map.has_key?(form, "client_secret")
      ["Basic " <> creds] = get_req_header(conn, "authorization")
      assert Base.decode64!(creds) == "cid:se%3Acret"
    end

    test "invalid_grant is terminal; another error is not and carries no body" do
      FakeProvider.stub(refresh_error: "invalid_grant")
      assert {:error, {:terminal, "invalid_grant"}} = OAuth.refresh(@endpoint, "r")

      FakeProvider.stub(refresh_error: "temporarily_unavailable")
      assert {:error, {:token, 400, "temporarily_unavailable"}} = OAuth.refresh(@endpoint, "r")
    end

    test "revoke posts the token, and without an endpoint does nothing" do
      FakeProvider.stub()
      assert :ok = OAuth.revoke(@endpoint, "tok")
      assert_received {:provider, "POST", "auth.example.com", "/revoke", %{"token" => "tok"}, _}

      assert {:error, :no_revocation_endpoint} =
               OAuth.revoke(%{@endpoint | revocation_endpoint: nil}, "tok")
    end
  end

  defp stub_metadata(overrides) do
    Req.Test.stub(OAuth, fn conn ->
      case {get_req_header(conn, "host"), conn.request_path} do
        {["mcp.example.com"], "/mcp"} ->
          send_resp(conn, 401, "")

        {_, "/.well-known/oauth-protected-resource/mcp"} ->
          json(conn, %{
            "resource" => "https://mcp.example.com/mcp",
            "authorization_servers" => ["https://auth.example.com"]
          })

        {_, "/.well-known/oauth-authorization-server"} ->
          json(
            conn,
            Map.merge(
              %{
                "issuer" => "https://auth.example.com",
                "authorization_endpoint" => "https://auth.example.com/authorize",
                "token_endpoint" => "https://auth.example.com/token",
                "code_challenge_methods_supported" => ["S256"]
              },
              overrides
            )
          )

        _ ->
          send_resp(conn, 404, "")
      end
    end)
  end

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end
end
