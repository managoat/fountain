defmodule Fountain.Connections.PlatformTest do
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "is what installed extensions contribute, in configured order, and core builds none" do
      # What this VM installs: the fixture always (config/test.exs), and a
      # real provider extension (fountain_google, fountain_microsoft,
      # fountain_slack) only where it loads — a root `mix test`, not a run
      # from apps/fountain — so membership is asserted rather than shape.
      assert Platform.builtin_slugs() == []

      assert %Provider{slug: "fixture-svc", user_id: nil, id: "fixture-svc"} =
               Enum.find(Platform.all(), &(&1.slug == "fixture-svc"))

      assert Platform.all() == Fountain.Extensions.connection_providers()
      assert Platform.slugs() == Enum.map(Platform.all(), & &1.slug)
      assert Provider.reserved_slugs() == Platform.slugs()
    end

    test "get/1 answers an installed extension's slug and nothing else" do
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

    test "names the config env var and the short name the console shows, by convention" do
      # ADR 0054 decision 5: `<SLUG>_OAUTH_CLIENT_ID`, and the slug capitalised.
      assert Platform.client_env_var(Platform.get("fixture-svc")) == "FIXTURE-SVC_OAUTH_CLIENT_ID"
      assert Platform.short_name(Platform.get("fixture-svc")) == "Fixture-svc"
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

      assert [%Provider{user_id: nil} | _] = contributed = Connections.all_providers(user.id)
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
    test "an extension's provider gets its own parameters, and they reach the URL" do
      # Google's offline pair and Slack's `user_scope` override live on their
      # extensions' structs now; the fixture proves the mechanism from core.
      p = Platform.get("fixture-svc")
      assert p.authorize_params == %{"prompt" => "fixture"}

      url = OAuth.authorize_url(p, "https://f.example/cb", "state123")
      query = URI.decode_query(URI.parse(url).query)
      assert query["prompt"] == "fixture"
      assert query["scope"] == "read"
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
    test "the client lifts a nested grant to the top level" do
      # Slack's `authed_user` nesting is the fountain_slack extension's now;
      # the field is exercised here on a tenant provider so core proves the
      # client's half without naming a service.
      user = insert_verified_user()
      p = insert_provider(user)
      nested = %Provider{p | token_body_nest: "authed_user"}

      Req.Test.stub(OAuth, fn req ->
        case req.request_path do
          "/oauth/token" ->
            Req.Test.json(req, %{
              "ok" => true,
              "authed_user" => %{
                "access_token" => "nested-1",
                "scope" => "read,write",
                "token_type" => "user"
              }
            })

          "/user" ->
            Req.Test.json(req, %{"login" => "jake"})
        end
      end)

      assert {:ok, grant} = OAuth.exchange_code(nested, "code-1", "https://f.example/cb")
      assert grant.access_token == "nested-1"
      assert grant.scopes == ~w(read write)
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
