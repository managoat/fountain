defmodule FountainGoogle.ProviderTest do
  @moduledoc """
  The Google provider is what the host's registry lists (ADR 0054), and it is
  the provider core used to build (#1178, #1299): same slug, endpoints,
  scopes, offline pair and env key, so a connection made before the move
  reads the same and the Gmail server beside it finds the same token.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}

  describe "the registry" do
    test "lists the provider, and get/1 answers the slug" do
      assert %Provider{slug: "google", user_id: nil, id: "google"} =
               google = Platform.get("google")

      assert google == FountainGoogle.Provider.provider()
      assert google in Platform.all()
      assert "google" in Platform.slugs()
      assert "google" in Provider.reserved_slugs()
      # Core builds none of its own any more (#2152 step 4b).
      assert Platform.builtin_slugs() == []
    end

    test "is the struct core used to build, field for field" do
      p = Platform.get("google")

      assert p.name == "Google (Gmail, Calendar)"
      assert p.kind == "oauth2"
      assert p.authorize_url == "https://accounts.google.com/o/oauth2/v2/auth"
      assert p.token_url == "https://oauth2.googleapis.com/token"
      assert p.revoke_url == "https://oauth2.googleapis.com/revoke"
      assert p.userinfo_url == "https://openidconnect.googleapis.com/v1/userinfo"
      assert p.account_label_path == "email"
      assert p.token_endpoint_auth == "client_secret_post"
      assert p.pkce == false
      assert p.env_key == "GOOGLE_ACCESS_TOKEN"
      # calendar/v3 lives on www.googleapis.com, which the broker binding covers
      assert p.token_hosts == ["gmail.googleapis.com", "www.googleapis.com"]
      assert p.client_source == "manual"
      assert p.token_body_nest == nil
      assert Provider.platform?(p)
    end

    test "asks for gmail and calendar, with the offline pair and incremental consent" do
      p = Platform.get("google")

      assert p.scopes == FountainGoogle.Provider.default_scopes()
      assert "https://www.googleapis.com/auth/gmail.modify" in p.scopes
      assert "https://www.googleapis.com/auth/calendar" in p.scopes

      assert p.authorize_params == %{
               "access_type" => "offline",
               "prompt" => "consent",
               "include_granted_scopes" => "true"
             }
    end

    test "is configured from config :fountain_google, under the conventional env var" do
      # config/test.exs sets the client pair under this app, not under :fountain.
      p = Platform.get("google")

      assert p.client_id == "google-test-client-id"
      assert p.client_secret == "google-test-client-secret"
      assert OAuth.configured?(p)
      assert Platform.client_env_var(p) == "GOOGLE_OAUTH_CLIENT_ID"
      assert Platform.short_name(p) == "Google"
    end

    test "a tenant cannot take the slug" do
      user = insert_verified_user()

      assert {:error, cs} =
               Connections.create_provider(user.id, provider_attrs(%{"slug" => "google"}))

      assert "is a platform provider" in errors_on(cs).slug
    end
  end

  describe "the host's OAuth client drives it" do
    test "the authorize URL asks for offline access with a forced consent, so a refresh token comes back" do
      url =
        OAuth.authorize_url(
          Platform.get("google"),
          "https://f.example/connections/google/callback",
          "st"
        )

      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")
      params = URI.decode_query(URI.parse(url).query)

      assert params["access_type"] == "offline"
      assert params["prompt"] == "consent"
      assert params["include_granted_scopes"] == "true"
      assert params["state"] == "st"
      assert params["client_id"] == "google-test-client-id"
      assert params["redirect_uri"] == "https://f.example/connections/google/callback"
      assert params["scope"] =~ "gmail.modify"
      assert params["scope"] =~ "auth/calendar"
      refute Map.has_key?(params, "code_challenge")
    end

    test "a consent whose token expires still insists on a refresh token" do
      Req.Test.stub(OAuth, fn conn ->
        Req.Test.json(conn, %{"access_token" => "ya29-1", "expires_in" => 3600})
      end)

      assert {:error, :no_refresh_token} =
               OAuth.exchange_code(Platform.get("google"), "code", "https://f.example/cb")
    end

    test "a connection on it is a platform connection with the two Google hosts implicit" do
      user = insert_verified_user()
      conn = insert_connection(user, provider: "google", account_email: "me@example.com")

      assert conn.provider == "google"
      assert conn.provider_id == nil
      assert conn.env_key == "GOOGLE_ACCESS_TOKEN"
      assert %Provider{slug: "google", user_id: nil} = Connections.provider_for(conn)

      assert Connections.implicit_hosts(user.id, "GOOGLE_ACCESS_TOKEN") ==
               ["gmail.googleapis.com", "www.googleapis.com"]
    end
  end
end
