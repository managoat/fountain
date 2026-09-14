defmodule Fountain.Connections.PlatformTest do
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "lists every platform provider, configured or not, in catalog order" do
      assert [
               %Provider{slug: "google", user_id: nil, id: "google"},
               %Provider{slug: "microsoft", user_id: nil, id: "microsoft"},
               %Provider{slug: "slack", user_id: nil, id: "slack"}
             ] = Platform.all()

      assert Platform.slugs() == ~w(google microsoft slack)
      assert Provider.reserved_slugs() == Platform.slugs()
    end

    test "get/1 answers a platform slug and nothing else" do
      assert %Provider{slug: "microsoft"} = Platform.get("microsoft")
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
        # config/test.exs sets all three client id/secret pairs
        assert OAuth.configured?(p)
      end
    end

    test "names the config env var and the short name the console shows" do
      assert Platform.client_env_var(Platform.get("slack")) == "SLACK_OAUTH_CLIENT_ID"
      assert Platform.client_env_var(Platform.get("microsoft")) == "MICROSOFT_OAUTH_CLIENT_ID"
      assert Platform.short_name(Platform.get("google")) == "Google"
      assert Platform.short_name(Platform.get("microsoft")) == "Microsoft"
    end

    test "google asks for gmail and calendar; microsoft keeps offline_access" do
      assert "https://www.googleapis.com/auth/calendar" in Platform.get("google").scopes
      assert "https://www.googleapis.com/auth/gmail.modify" in Platform.get("google").scopes
      assert "offline_access" in Platform.get("microsoft").scopes
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

  describe "authorize_params on the struct" do
    test "google sends the offline pair with incremental consent" do
      assert %{
               "access_type" => "offline",
               "prompt" => "consent",
               "include_granted_scopes" => "true"
             } = Platform.get("google").authorize_params
    end

    test "microsoft asks for an account picker" do
      assert Platform.get("microsoft").authorize_params == %{"prompt" => "select_account"}
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
