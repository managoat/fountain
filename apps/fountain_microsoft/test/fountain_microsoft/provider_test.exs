defmodule FountainMicrosoft.ProviderTest do
  @moduledoc """
  The Microsoft provider is what the host's registry lists (ADR 0054), and it
  is the provider core used to build (#1299): same slug, endpoints, scopes,
  quirks and env key, so a connection made before the move reads the same.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "lists the provider after the host's own, and get/1 answers the slug" do
      assert %Provider{slug: "microsoft", user_id: nil, id: "microsoft"} =
               microsoft = Platform.get("microsoft")

      assert microsoft == FountainMicrosoft.Provider.provider()
      assert microsoft in Platform.all()
      assert "microsoft" in Platform.slugs()
      assert "microsoft" in Provider.reserved_slugs()

      # After the host's own: an extension's rows follow the core registry.
      refute "microsoft" in Platform.builtin_slugs()
      host = Enum.map(Platform.builtin_slugs(), &Platform.get/1)
      assert Enum.drop(Platform.all(), length(host)) |> Enum.any?(&(&1.slug == "microsoft"))
    end

    test "is the struct core used to build, field for field" do
      p = Platform.get("microsoft")

      assert p.name == "Microsoft (Outlook, Calendar, Teams)"
      assert p.kind == "oauth2"
      assert p.authorize_url == "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
      assert p.token_url == "https://login.microsoftonline.com/common/oauth2/v2.0/token"
      assert p.revoke_url == nil
      assert p.userinfo_url == "https://graph.microsoft.com/v1.0/me"
      assert p.account_label_path == "userPrincipalName"
      assert p.token_endpoint_auth == "client_secret_post"
      assert p.pkce == true
      assert p.env_key == "MICROSOFT_ACCESS_TOKEN"
      assert p.token_hosts == ["graph.microsoft.com"]
      assert p.client_source == "manual"
      assert p.token_body_nest == nil
      assert Provider.platform?(p)
    end

    test "asks for an account picker, and keeps offline_access" do
      p = Platform.get("microsoft")

      assert p.authorize_params == %{"prompt" => "select_account"}
      assert p.scopes == FountainMicrosoft.Provider.default_scopes()
      assert "offline_access" in p.scopes
      assert Enum.any?(p.scopes, &(&1 =~ ~r/mail/i))
      assert Enum.any?(p.scopes, &(&1 =~ ~r/calendar/i))
      assert Enum.any?(p.scopes, &(&1 =~ ~r/chat/i))
    end

    test "is configured from config :fountain_microsoft, under the conventional env var" do
      # config/test.exs sets the client pair under this app, not under :fountain.
      p = Platform.get("microsoft")

      assert p.client_id == "microsoft-test-client-id"
      assert p.client_secret == "microsoft-test-client-secret"
      assert OAuth.configured?(p)
      assert Platform.client_env_var(p) == "MICROSOFT_OAUTH_CLIENT_ID"
      assert Platform.short_name(p) == "Microsoft"
    end

    test "a tenant cannot take the slug" do
      user = insert_verified_user()

      assert {:error, cs} =
               Connections.create_provider(user.id, provider_attrs(%{"slug" => "microsoft"}))

      assert "is a platform provider" in errors_on(cs).slug
    end
  end

  describe "the host's OAuth client drives it" do
    test "the authorize URL carries the picker, PKCE and the scopes" do
      verifier = OAuth.code_verifier()

      url =
        OAuth.authorize_url(
          Platform.get("microsoft"),
          "https://f.example/cb",
          "state123",
          verifier
        )

      query = URI.decode_query(URI.parse(url).query)

      assert String.starts_with?(
               url,
               "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"
             )

      assert query["prompt"] == "select_account"
      assert query["client_id"] == "microsoft-test-client-id"
      assert query["code_challenge_method"] == "S256"
      assert query["scope"] =~ "offline_access"
    end

    test "a token that expires still insists on a refresh token" do
      Req.Test.stub(OAuth, fn conn ->
        Req.Test.json(conn, %{"access_token" => "graph-1", "expires_in" => 3600})
      end)

      assert {:error, :no_refresh_token} =
               OAuth.exchange_code(Platform.get("microsoft"), "code", "https://f.example/cb")
    end

    test "a connection on it is a platform connection with the Graph host implicit" do
      user = insert_verified_user()
      conn = insert_connection(user, provider: "microsoft", account_email: "me@corp.example")

      assert conn.provider_id == nil
      assert conn.env_key == "MICROSOFT_ACCESS_TOKEN"
      assert %Provider{slug: "microsoft", user_id: nil} = Connections.provider_for(conn)

      assert Connections.implicit_hosts(user.id, "MICROSOFT_ACCESS_TOKEN") ==
               ["graph.microsoft.com"]
    end
  end
end
