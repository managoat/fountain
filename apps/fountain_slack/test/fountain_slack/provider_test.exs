defmodule FountainSlack.ProviderTest do
  @moduledoc """
  The Slack provider is what the host's registry lists (ADR 0054), and it is
  the provider core used to build (#1299): same slug, endpoints, scopes,
  quirks and env key, so a connection made before the move reads the same.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "lists the provider after the host's own, and get/1 answers the slug" do
      assert %Provider{slug: "slack", user_id: nil, id: "slack"} = slack = Platform.get("slack")

      assert slack == FountainSlack.Provider.provider()
      assert slack in Platform.all()
      assert "slack" in Platform.slugs()
      assert "slack" in Provider.reserved_slugs()

      # After the host's own: an extension's rows follow the core registry.
      refute "slack" in Platform.builtin_slugs()
      host = Enum.map(Platform.builtin_slugs(), &Platform.get/1)
      assert Enum.drop(Platform.all(), length(host)) |> Enum.any?(&(&1.slug == "slack"))
    end

    test "is the struct core used to build, field for field" do
      p = Platform.get("slack")

      assert p.name == "Slack"
      assert p.kind == "oauth2"
      assert p.authorize_url == "https://slack.com/oauth/v2/authorize"
      assert p.token_url == "https://slack.com/api/oauth.v2.access"
      assert p.revoke_url == "https://slack.com/api/auth.revoke"
      assert p.userinfo_url == "https://slack.com/api/auth.test"
      assert p.account_label_path == "user"
      assert p.token_endpoint_auth == "client_secret_post"
      assert p.pkce == false
      assert p.env_key == "SLACK_ACCESS_TOKEN"
      assert p.token_hosts == ["slack.com"]
      assert p.client_source == "manual"
      assert Provider.platform?(p)
    end

    test "asks for user scopes, not bot scopes, and nests its token body" do
      p = Platform.get("slack")

      assert p.scopes == FountainSlack.Provider.default_scopes()
      assert "chat:write" in p.scopes
      assert p.authorize_params == %{"scope" => "", "user_scope" => Enum.join(p.scopes, " ")}
      assert p.token_body_nest == "authed_user"
    end

    test "is configured from config :fountain_slack, under the conventional env var" do
      # config/test.exs sets the client pair under this app, not under :fountain.
      p = Platform.get("slack")

      assert p.client_id == "slack-test-client-id"
      assert p.client_secret == "slack-test-client-secret"
      assert OAuth.configured?(p)
      assert Platform.client_env_var(p) == "SLACK_OAUTH_CLIENT_ID"
      assert Platform.short_name(p) == "Slack"
    end

    test "a tenant cannot take the slug" do
      user = insert_verified_user()

      assert {:error, cs} =
               Connections.create_provider(user.id, provider_attrs(%{"slug" => "slack"}))

      assert "is a platform provider" in errors_on(cs).slug
    end
  end

  describe "the host's OAuth client drives it" do
    test "the authorize URL moves the request to user_scope and empties scope" do
      url = OAuth.authorize_url(Platform.get("slack"), "https://f.example/cb", "state123")
      query = URI.decode_query(URI.parse(url).query)

      assert String.starts_with?(url, "https://slack.com/oauth/v2/authorize?")
      assert query["scope"] == ""
      assert query["user_scope"] =~ "chat:write"
      assert query["client_id"] == "slack-test-client-id"
      refute Map.has_key?(query, "code_challenge")
    end

    test "an exchange lifts authed_user, needs no refresh token, labels via auth.test" do
      slack = Platform.get("slack")

      Req.Test.stub(OAuth, fn conn ->
        case conn.request_path do
          "/api/oauth.v2.access" ->
            Req.Test.json(conn, %{
              "ok" => true,
              "app_id" => "A1",
              "authed_user" => %{
                "id" => "U1",
                "access_token" => "xoxp-99",
                "scope" => "channels:history,chat:write",
                "token_type" => "user"
              }
            })

          "/api/auth.test" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxp-99"]
            Req.Test.json(conn, %{"ok" => true, "user" => "jake", "team" => "goat"})
        end
      end)

      assert {:ok, grant} = OAuth.exchange_code(slack, "code", "https://f.example/cb")
      assert grant.access_token == "xoxp-99"
      assert grant.refresh_token == nil
      assert grant.expires_at == nil
      assert grant.scopes == ["channels:history", "chat:write"]
      assert grant.account_email == "jake"
    end

    test "a connection on it is a platform connection with slack.com implicit" do
      user = insert_verified_user()
      conn = insert_connection(user, provider: "slack", account_email: "jake")

      assert conn.provider_id == nil
      assert conn.env_key == "SLACK_ACCESS_TOKEN"
      assert %Provider{slug: "slack", user_id: nil} = Connections.provider_for(conn)
      assert Connections.implicit_hosts(user.id, "SLACK_ACCESS_TOKEN") == ["slack.com"]

      # the same handle again replaces the row rather than adding one
      again = insert_connection(user, provider: "slack", account_email: "jake")
      assert again.id == conn.id
      assert length(Connections.list_connections(user.id)) == 1
    end
  end
end
