defmodule Fountain.Connections.ProviderTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Connections, Crypto}
  alias Fountain.Connections.{Connection, McpServers, OAuth, Provider}

  describe "create_provider/3" do
    test "stores a tenant oauth2 provider with the secret encrypted and the env key derived" do
      user = insert_verified_user()
      p = insert_provider(user, slug: "github", name: "GitHub", client_secret: "shh")

      assert p.kind == "oauth2"
      assert p.env_key == "GITHUB_ACCESS_TOKEN"
      assert p.user_id == user.id
      refute p.client_secret_ciphertext == "shh"
      assert is_nil(p.client_secret)

      {:ok, dek} = Crypto.load_tenant_key(user.id)
      assert {:ok, "shh"} = Crypto.decrypt(p.client_secret_ciphertext, dek)
      assert {:ok, %Provider{client_secret: "shh"}} = Connections.unlock_provider(p)

      assert [_] = Connections.list_providers(user.id)

      # The two the host owns, then whatever the installed extensions
      # contribute (ADR 0054; always the fixture's, and fountain_microsoft's
      # where that app loads), then the tenant's own.
      assert [
               %Provider{slug: "google", user_id: nil},
               %Provider{slug: "slack", user_id: nil}
               | contributed
             ] = Connections.all_providers(user.id)

      assert %Provider{slug: "fixture-svc", user_id: nil} =
               Enum.find(contributed, &(&1.slug == "fixture-svc"))

      assert List.last(contributed) == p

      assert Connections.redirect_uri(p) =~ "/connections/#{p.id}/callback"
    end

    test "refuses the platform slug, wildcard hosts, private and non-https URLs" do
      user = insert_verified_user()

      base = %{
        "name" => "X",
        "authorize_url" => "https://x.example/a",
        "token_url" => "https://x.example/t",
        "client_id" => "c",
        "client_secret" => "s"
      }

      assert {:error, cs} = Connections.create_provider(user.id, Map.put(base, "slug", "google"))
      assert "is a platform provider" in errors_on(cs).slug

      assert {:error, cs} =
               Connections.create_provider(
                 user.id,
                 Map.merge(base, %{"slug" => "x", "token_hosts" => ["*"]})
               )

      assert "may not contain a wildcard" in errors_on(cs).token_hosts

      assert {:error, cs} =
               Connections.create_provider(
                 user.id,
                 Map.merge(base, %{"slug" => "x", "token_url" => "http://x.example/t"})
               )

      assert "must be an https URL" in errors_on(cs).token_url

      assert {:error, cs} =
               Connections.create_provider(
                 user.id,
                 Map.merge(base, %{"slug" => "x", "authorize_url" => "https://10.0.0.1/a"})
               )

      assert "must be a hostname, not an IP address" in errors_on(cs).authorize_url

      assert {:error, cs} =
               Connections.create_provider(
                 user.id,
                 Map.merge(base, %{
                   "slug" => "x",
                   "authorize_url" => "https://metadata.google.internal/a"
                 })
               )

      assert "must not be an internal host" in errors_on(cs).authorize_url

      assert {:error, cs} =
               Connections.create_provider(
                 user.id,
                 Map.merge(base, %{"slug" => "x", "client_secret" => ""})
               )

      assert "can't be blank" in errors_on(cs).client_secret

      # A public client needs no secret.
      assert {:ok, _} =
               Connections.create_provider(
                 user.id,
                 Map.merge(base, %{
                   "slug" => "pub",
                   "client_secret" => "",
                   "token_endpoint_auth" => "none"
                 })
               )
    end

    test "slugs and env keys are unique per tenant, and reads are tenant-scoped" do
      a = insert_verified_user()
      b = insert_verified_user()
      p = insert_provider(a, slug: "github")

      assert {:error, cs} = Connections.create_provider(a.id, provider_attrs(slug: "github"))
      assert errors_on(cs).slug
      assert {:ok, _} = Connections.create_provider(b.id, provider_attrs(slug: "github"))

      assert Connections.get_provider(p.id, a.id)
      refute Connections.get_provider(p.id, b.id)
      refute Connections.get_provider("nope", a.id)
      assert %Provider{slug: "google"} = Connections.get_provider("google", b.id)
    end

    test "update keeps the secret when blank and audits the changed fields; delete takes the connections" do
      user = insert_verified_user()
      p = insert_provider(user, client_secret: "first")
      Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)
      c = insert_connection(user, provider: p, account_email: "me")

      assert {:ok, p2} =
               Connections.update_provider(p, %{"name" => "Renamed", "client_secret" => ""})

      assert p2.name == "Renamed"
      assert p2.client_secret_ciphertext == p.client_secret_ciphertext

      assert {:ok, p3} = Connections.update_provider(p2, %{"client_secret" => "second"})
      assert {:ok, %Provider{client_secret: "second"}} = Connections.unlock_provider(p3)

      events = Fountain.Audit.list_recent_for_user(user.id)
      updated = Enum.filter(events, &(&1.action == "connection_provider.updated"))
      assert Enum.any?(updated, &("name" in &1.metadata["changed"]))
      refute Enum.any?(events, fn e -> inspect(e.metadata) =~ "second" end)

      assert {:ok, _} = Connections.delete_provider(p3)
      refute Connections.get_provider(p.id, user.id)
      refute Connections.get_connection(c.id, user.id)

      assert Enum.any?(
               events ++ Fountain.Audit.list_recent_for_user(user.id),
               &(&1.action == "connection_provider.deleted")
             )
    end
  end

  describe "connections on a tenant provider" do
    test "connect stores the provider's slug and id and takes the provider's env key" do
      user = insert_verified_user()
      p = insert_provider(user, slug: "github")
      c = insert_connection(user, provider: p, account_email: "octocat")

      assert c.provider == "github"
      assert c.provider_id == p.id
      assert c.env_key == "GITHUB_ACCESS_TOKEN"
      assert Connections.provider_for(c).id == p.id

      c2 = insert_connection(user, provider: p, account_email: "hubot")
      assert c2.env_key == "GITHUB_ACCESS_TOKEN_2"

      assert Connections.implicit_hosts(user.id, "GITHUB_ACCESS_TOKEN_2") == ["api.svc.example"]
      assert Connections.implicit_hosts(user.id, "NOPE") == []
    end

    test "a grant with no refresh token is active until the token lapses, then expired" do
      user = insert_verified_user()
      p = insert_provider(user)
      Req.Test.stub(OAuth, fn _ -> flunk("nothing to refresh with") end)

      soon = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      live =
        insert_connection(user,
          provider: p,
          refresh_token: nil,
          access_token: "a-1",
          expires_at: soon
        )

      assert is_nil(live.refresh_token_ciphertext)
      assert {:ok, "a-1"} = Connections.access_token(live)

      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      c =
        insert_connection(user,
          provider: p,
          refresh_token: nil,
          access_token: "a-1",
          expires_at: past
        )

      assert {:error, :expired} = Connections.access_token(c)
      assert %Connection{status: "expired"} = Connections.get_connection(c.id, user.id)
      assert Connections.synthetic_secrets(user.id) == %{live.env_key => "a-1"}

      actions = user.id |> Fountain.Audit.list_recent_for_user() |> Enum.map(& &1.action)
      assert "connection.expired" in actions

      # Reconnecting the same account replaces it and reactivates.
      c =
        insert_connection(user,
          provider: p,
          refresh_token: nil,
          access_token: "a-2",
          expires_at: nil
        )

      assert c.status == "active"
      assert {:ok, "a-2"} = Connections.access_token(c)
    end

    test "a token with no known expiry is served without a refresh" do
      user = insert_verified_user()
      p = insert_provider(user)
      Req.Test.stub(OAuth, fn _ -> flunk("no expiry, no refresh") end)
      c = insert_connection(user, provider: p, access_token: "forever", expires_at: nil)
      assert {:ok, "forever"} = Connections.access_token(c)
    end

    test "refresh rotates the refresh token when the provider sends a new one, with basic client auth" do
      user = insert_verified_user()

      p =
        insert_provider(user,
          token_endpoint_auth: "client_secret_basic",
          client_id: "cid",
          client_secret: "csec"
        )

      soon = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      c =
        insert_connection(user,
          provider: p,
          refresh_token: "r-1",
          access_token: "a-old",
          expires_at: soon
        )

      Req.Test.stub(OAuth, fn req ->
        assert req.request_path == "/oauth/token"

        assert Plug.Conn.get_req_header(req, "authorization") == [
                 "Basic " <> Base.encode64("cid:csec")
               ]

        {:ok, body, _} = Plug.Conn.read_body(req)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "r-1"
        refute Map.has_key?(params, "client_secret")

        Req.Test.json(req, %{
          "access_token" => "a-new",
          "refresh_token" => "r-2",
          "expires_in" => 100
        })
      end)

      assert {:ok, "a-new"} = Connections.access_token(c)
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      stored = Connections.get_connection(c.id, user.id)
      assert {:ok, "r-2"} = Crypto.decrypt(stored.refresh_token_ciphertext, dek)
    end

    test "a stale struct does not replay an already-rotated refresh token" do
      user = insert_verified_user()
      p = insert_provider(user)
      soon = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      c =
        insert_connection(user,
          provider: p,
          refresh_token: "r-1",
          access_token: "a-old",
          expires_at: soon
        )

      Req.Test.stub(OAuth, fn req ->
        {:ok, body, _} = Plug.Conn.read_body(req)
        assert URI.decode_query(body)["refresh_token"] == "r-1"

        Req.Test.json(req, %{
          "access_token" => "a-new",
          "refresh_token" => "r-2",
          "expires_in" => 7200
        })
      end)

      assert {:ok, "a-new"} = Connections.access_token(c)

      # A provider that rotates strictly refuses a replayed refresh token.
      Req.Test.stub(OAuth, fn req ->
        req |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      # The caller that lost the race still holds the pre-rotation struct.
      # The refresh path must re-read the row under its lock and serve the
      # fresh token — not replay "r-1" and revoke a valid connection.
      assert {:ok, "a-new"} = Connections.access_token(c)
      assert %Connection{status: "active"} = Connections.get_connection(c.id, user.id)
    end

    test "an error in a 200 body (Slack's shape) is an error, and invalid grants revoke" do
      user = insert_verified_user()
      p = insert_provider(user)
      soon = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
      c = insert_connection(user, provider: p, refresh_token: "r-1", expires_at: soon)

      Req.Test.stub(OAuth, fn req ->
        Req.Test.json(req, %{"ok" => false, "error" => "invalid_refresh_token"})
      end)

      assert {:error, :revoked} = Connections.access_token(c)
      assert %Connection{status: "revoked"} = Connections.get_connection(c.id, user.id)

      # A transient 200 error leaves the connection alone.
      c2 = insert_connection(user, provider: p, refresh_token: "r-2", expires_at: soon)

      Req.Test.stub(OAuth, fn req ->
        Req.Test.json(req, %{"ok" => false, "error" => "ratelimited"})
      end)

      assert {:error, {:http, 200, _}} = Connections.access_token(c2)
      assert %Connection{status: "active"} = Connections.get_connection(c2.id, user.id)
    end

    test "renaming a provider's slug follows its connections, and reconnect finds the same row" do
      user = insert_verified_user()
      p = insert_provider(user, slug: "github")
      c = insert_connection(user, provider: p, account_email: "octocat")
      assert c.provider == "github"

      assert {:ok, p2} = Connections.update_provider(p, %{"slug" => "github-org"})
      assert %Connection{provider: "github-org"} = Connections.get_connection(c.id, user.id)

      c2 = insert_connection(user, provider: p2, account_email: "octocat")
      assert c2.id == c.id
      assert c2.env_key == c.env_key
      assert [_] = Connections.list_connections(user.id)
    end

    test "a provider's own invalid-grant spelling marks the connection revoked" do
      user = insert_verified_user()
      p = insert_provider(user)
      soon = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
      c = insert_connection(user, provider: p, refresh_token: "r-1", expires_at: soon)

      Req.Test.stub(OAuth, fn req ->
        req |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad_refresh_token"})
      end)

      assert {:error, :revoked} = Connections.access_token(c)
      assert %Connection{status: "revoked"} = Connections.get_connection(c.id, user.id)
    end

    test "revoke posts the token to revoke_url (RFC 7009) and is local-only without one" do
      user = insert_verified_user()
      with_revoke = insert_provider(user, revoke_url: "https://svc.example/oauth/revoke")
      c = insert_connection(user, provider: with_revoke, refresh_token: "r-1")

      Req.Test.stub(OAuth, fn req ->
        assert req.request_path == "/oauth/revoke"
        {:ok, body, _} = Plug.Conn.read_body(req)
        assert URI.decode_query(body)["token"] == "r-1"
        Req.Test.json(req, %{})
      end)

      assert {:ok, %Connection{status: "revoked"}} = Connections.revoke(c)

      without = insert_provider(user)
      c2 = insert_connection(user, provider: without, refresh_token: "r-2")
      Req.Test.stub(OAuth, fn _ -> flunk("no revoke_url, no call") end)
      assert {:ok, %Connection{status: "revoked"}} = Connections.revoke(c2)
    end
  end

  describe "OAuth.exchange_code/4 on a tenant provider" do
    test "sends PKCE, the client secret in the body, and reads the label from the userinfo path" do
      user = insert_verified_user()

      p =
        insert_provider(user,
          pkce: true,
          account_label_path: "data.login",
          client_id: "cid",
          client_secret: "csec"
        )

      {:ok, p} = Connections.unlock_provider(p)
      verifier = OAuth.code_verifier()
      url = OAuth.authorize_url(p, "https://f.example/cb", "st", verifier)
      q = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert q["code_challenge_method"] == "S256"

      assert q["code_challenge"] ==
               :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      assert q["client_id"] == "cid"
      refute Map.has_key?(q, "access_type")

      Req.Test.stub(OAuth, fn req ->
        case req.request_path do
          "/oauth/token" ->
            {:ok, body, _} = Plug.Conn.read_body(req)
            form = URI.decode_query(body)
            assert form["code_verifier"] == verifier
            assert form["client_secret"] == "csec"
            # GitHub's shape: no expiry, no refresh token, a form-encoded body.
            Plug.Conn.send_resp(
              req,
              200,
              "access_token=gho_1&scope=repo%2Cread%3Auser&token_type=bearer"
            )

          "/user" ->
            assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer gho_1"]
            Req.Test.json(req, %{"data" => %{"login" => "octocat"}})
        end
      end)

      assert {:ok, grant} = OAuth.exchange_code(p, "code", "https://f.example/cb", verifier)
      assert grant.access_token == "gho_1"
      assert grant.account_email == "octocat"
      assert is_nil(grant.refresh_token)
      assert is_nil(grant.expires_at)
      assert grant.scopes == ["repo", "read:user"]
    end

    test "a provider without userinfo leaves the label to the caller, who names it at connect" do
      user = insert_verified_user()
      p = insert_provider(user, userinfo_url: nil, account_label_path: nil)
      {:ok, p} = Connections.unlock_provider(p)

      Req.Test.stub(OAuth, fn req ->
        Req.Test.json(req, %{"access_token" => "t", "expires_in" => 10})
      end)

      assert {:ok, %{account_email: nil} = grant} =
               OAuth.exchange_code(p, "code", "https://f.example/cb")

      assert {:ok, c} = Connections.connect(user.id, p, grant, account_label: "work")
      assert c.account_email == "work"
      assert {:ok, c} = Connections.connect(user.id, p, grant)
      assert c.account_email == p.name
    end
  end

  describe "McpServers with a remote server" do
    test "resolve swaps the connection for a placeholder bearer and remote_hosts names the host" do
      user = insert_verified_user()
      p = insert_provider(user, slug: "linear")
      c = insert_connection(user, provider: p, account_email: "me")
      by_id = %{c.id => c}

      servers = %{
        "linear" => %{
          "type" => "http",
          "url" => "https://mcp.linear.app/mcp",
          "connection" => c.id
        },
        "gmail" => %{"connection" => Ecto.UUID.generate()},
        "fs" => %{"command" => "npx"}
      }

      resolved = McpServers.resolve(servers, "conv", "cb-token", by_id)

      assert resolved["linear"] == %{
               "type" => "http",
               "url" => "https://mcp.linear.app/mcp",
               "headers" => %{"Authorization" => "Bearer __linear_access_token__"}
             }

      assert resolved["gmail"]["url"] =~ "/api/mcp/gmail/conv/"
      assert resolved["fs"] == %{"command" => "npx"}

      assert McpServers.remote_hosts(servers, by_id) == %{
               "LINEAR_ACCESS_TOKEN" => ["mcp.linear.app"]
             }

      # An unknown or inactive connection drops the remote entry rather than
      # shipping a URL the broker would not attach anything to.
      assert McpServers.resolve(servers, "conv", "cb-token", %{}) |> Map.keys() |> Enum.sort() ==
               ["fs", "gmail"]

      assert McpServers.remote_hosts(servers, %{}) == %{}

      assert Enum.sort(McpServers.connection_ids(servers)) ==
               Enum.sort([c.id, servers["gmail"]["connection"]])
    end
  end
end
