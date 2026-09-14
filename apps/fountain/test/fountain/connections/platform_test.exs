defmodule Fountain.Connections.PlatformTest do
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "lists every platform provider, configured or not: the host's in catalog order, then each installed extension's" do
      # The host's own come first. What follows depends on which extensions
      # this VM installs — the fixture always (config/test.exs), and a real
      # provider extension such as fountain_microsoft only where it loads
      # (a root `mix test`, not a run from apps/fountain) — so the tail is
      # asserted by membership rather than by shape.
      assert [
               %Provider{slug: "google", user_id: nil, id: "google"},
               %Provider{slug: "slack", user_id: nil, id: "slack"}
               | contributed
             ] = Platform.all()

      assert %Provider{slug: "fixture-svc", user_id: nil, id: "fixture-svc"} =
               Enum.find(contributed, &(&1.slug == "fixture-svc"))

      assert Platform.builtin_slugs() == ~w(google slack)
      assert Platform.slugs() == Enum.map(Platform.all(), & &1.slug)
      assert Provider.reserved_slugs() == Platform.slugs()
    end

    test "get/1 answers a platform slug, the host's or an extension's, and nothing else" do
      assert %Provider{slug: "slack"} = Platform.get("slack")
      assert %Provider{slug: "fixture-svc", name: "Fixture service"} = Platform.get("fixture-svc")
      assert Platform.get("github") == nil
      assert Platform.get(Ecto.UUID.generate()) == nil
    end

    test "every provider is a valid oauth2 record the shared client can drive" do
      for p <- Platform.all() do
        assert p.kind == "oauth2"
        assert Provider.platform?(p)
        assert p.authorize_url =~ "https://"
        assert p.token_url =~ "https://"
        assert p.env_key =~ ~r/^[A-Z_]+_ACCESS_TOKEN$/
        assert p.token_hosts != []
        # config/test.exs sets every platform client id/secret pair
        assert OAuth.configured?(p)
      end
    end

    test "names the config env var and the short name the console shows" do
      assert Platform.client_env_var(Platform.get("slack")) == "SLACK_OAUTH_CLIENT_ID"
      assert Platform.short_name(Platform.get("google")) == "Google"
    end

    test "google asks for gmail and calendar" do
      assert "https://www.googleapis.com/auth/calendar" in Platform.get("google").scopes
      assert "https://www.googleapis.com/auth/gmail.modify" in Platform.get("google").scopes
      # calendar/v3 lives on www.googleapis.com, which the broker binding covers
      assert "www.googleapis.com" in Platform.get("google").token_hosts
    end

    test "a tenant cannot take a platform slug" do
      user = insert_verified_user()

      for slug <- Platform.slugs() do
        assert {:error, cs} =
                 Connections.create_provider(user.id, provider_attrs(%{"slug" => slug}))

        assert "is a platform provider" in errors_on(cs).slug
      end
    end
  end

  describe "an extension's provider (ADR 0054)" do
    test "is one more platform provider to every caller in core" do
      user = insert_verified_user()
      own = insert_provider(user)

      assert [_google, _slack | contributed] = Connections.all_providers(user.id)
      assert List.last(contributed) == own

      assert %Provider{slug: "fixture-svc"} =
               p = Enum.find(contributed, &(&1.slug == "fixture-svc"))

      assert Connections.get_provider("fixture-svc", user.id) == p
      assert Provider.platform?(p)
      assert OAuth.configured?(p)

      # The OAuth client reads its quirks off the struct like anyone else's.
      url = OAuth.authorize_url(p, "https://f.example/cb", "state123")
      query = URI.decode_query(URI.parse(url).query)
      assert query["prompt"] == "fixture"
      assert query["client_id"] == "fixture-client"
      assert query["code_challenge_method"] == "S256" or query["code_challenge"] == nil

      # A connection on it is a platform connection: no provider row, the
      # slug names the registry entry.
      grant = %{access_token: "t", refresh_token: "r", expires_at: nil, scopes: ["read"]}
      assert {:ok, conn} = Connections.connect(user.id, "fixture-svc", grant)
      assert conn.provider == "fixture-svc"
      assert conn.provider_id == nil
      assert %Provider{slug: "fixture-svc"} = Connections.provider_for(conn)
    end
  end

  describe "authorize_params on the struct" do
    test "google sends the offline pair with incremental consent" do
      assert %{
               "access_type" => "offline",
               "prompt" => "consent",
               "include_granted_scopes" => "true"
             } = Platform.get("google").authorize_params
    end

    test "slack moves the request to user_scope and empties scope" do
      slack = Platform.get("slack")

      assert slack.authorize_params["scope"] == ""
      assert slack.authorize_params["user_scope"] == Enum.join(slack.scopes, " ")

      # and the composed authorize URL carries that override
      url = OAuth.authorize_url(slack, "https://f.example/cb", "state123")
      query = URI.decode_query(URI.parse(url).query)
      assert query["scope"] == ""
      assert query["user_scope"] =~ "chat:write"
    end

    test "a tenant provider gets no extra parameters" do
      user = insert_verified_user()
      p = insert_provider(user)
      assert p.authorize_params == %{}

      url = OAuth.authorize_url(p, "https://f.example/cb", "state123")
      query = URI.decode_query(URI.parse(url).query)
      assert query["scope"] == "read"
      refute Map.has_key?(query, "user_scope")
      refute Map.has_key?(query, "prompt")
    end
  end

  describe "token_body_nest on the struct" do
    test "the client lifts slack's authed_user grant to the top level" do
      slack = Platform.get("slack")
      assert slack.token_body_nest == "authed_user"

      Req.Test.stub(OAuth, fn req ->
        case req.request_path do
          "/api/oauth.v2.access" ->
            Req.Test.json(req, %{
              "ok" => true,
              "app_id" => "A1",
              "authed_user" => %{
                "id" => "U1",
                "access_token" => "xoxp-1",
                "scope" => "channels:history,chat:write",
                "token_type" => "user"
              }
            })

          "/api/auth.test" ->
            Req.Test.json(req, %{"ok" => true, "user" => "jake"})
        end
      end)

      assert {:ok, grant} = OAuth.exchange_code(slack, "code-1", "https://f.example/cb")
      assert grant.access_token == "xoxp-1"
      assert grant.scopes == ~w(channels:history chat:write)
      assert grant.refresh_token == nil
      assert grant.account_email == "jake"
    end

    test "every other provider's body is read as it came" do
      user = insert_verified_user()
      p = insert_provider(user)
      assert p.token_body_nest == nil

      Req.Test.stub(OAuth, fn req ->
        case req.request_path do
          "/oauth/token" ->
            Req.Test.json(req, %{
              "access_token" => "a",
              "expires_in" => 3600,
              "authed_user" => %{"access_token" => "b"}
            })

          "/user" ->
            Req.Test.json(req, %{"login" => "jake"})
        end
      end)

      assert {:ok, %{access_token: "a"}} =
               OAuth.exchange_code(p, "code-1", "https://f.example/cb")
    end
  end
end
