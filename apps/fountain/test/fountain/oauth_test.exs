defmodule Fountain.OAuthTest do
  @moduledoc """
  Fountain's side of the OAuth seam (#1343): what `Fountain.OAuth.Host`
  decides (a token is an API key, a subject is a user who may hold one, the
  trail is `Fountain.Audit`) and that the registry is read from
  `config :fountain, Fountain.OAuth`. The grant state machine itself (every
  wrong grant, expiry, single use, the two orderings) is tested in
  `test/managoat/oauth/`.
  """
  use Fountain.DataCase, async: true

  alias Fountain.{Accounts, Audit, OAuth}

  @client "test-app"
  @redirect "https://app.test/callback"

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  defp request(challenge) do
    %{
      "client_id" => @client,
      "redirect_uri" => @redirect,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }
  end

  defp exchange(code, verifier, opts \\ []) do
    OAuth.exchange(
      %{
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => @client,
        "redirect_uri" => @redirect
      },
      opts
    )
  end

  describe "the operator registry, config :fountain, Fountain.OAuth" do
    test "is read as published clients" do
      assert [
               %{
                 id: @client,
                 name: "Test App",
                 redirect_uris: [@redirect, _],
                 published: true,
                 owner_id: nil,
                 record_id: nil
               }
             ] = OAuth.config_clients()

      assert %{id: @client} = OAuth.get_client(@client)
    end
  end

  describe "validate_request/2, PKCE" do
    test "the method defaults to S256 and nothing else is accepted" do
      {_verifier, challenge} = pkce()
      assert {:ok, %{id: @client}} = OAuth.validate_request(request(challenge))

      assert {:ok, _} =
               OAuth.validate_request(Map.delete(request(challenge), "code_challenge_method"))

      assert {:error, :unsupported_code_challenge_method} =
               OAuth.validate_request(%{request(challenge) | "code_challenge_method" => "plain"})
    end

    test "the challenge must be 43 to 128 base64url characters" do
      assert {:error, :invalid_code_challenge} = OAuth.validate_request(request("short"))
      assert {:error, :invalid_code_challenge} = OAuth.validate_request(request(nil))

      assert {:error, :invalid_code_challenge} =
               OAuth.validate_request(request(String.duplicate("a", 129)))

      assert {:ok, _} = OAuth.validate_request(request(String.duplicate("a", 43)))
    end

    test "a configured client gets an exact redirect match" do
      {_verifier, challenge} = pkce()

      for uri <- ["https://app.test/callback?x=1", "https://evil.test/", "http://localhost:5174/"] do
        assert {:error, :redirect_uri_mismatch} =
                 OAuth.validate_request(%{request(challenge) | "redirect_uri" => uri})
      end
    end
  end

  describe "a code exchange mints an API key" do
    test "named oauth:<client>, 30 days, full scope, that authenticates — and audits" do
      user = insert_verified_user()
      {verifier, challenge} = pkce()

      assert {:ok, code} =
               OAuth.authorize(user.id, request(challenge), actor: "ui", request_ip: "9.9.9.9")

      assert {:ok, %{access_token: token, expires_in: ttl, api_key: key}} =
               exchange(code, verifier, request_ip: "9.9.9.9")

      assert ttl == OAuth.token_ttl_seconds()
      assert %Accounts.ApiKey{} = key
      assert key.name == "oauth:test-app"
      assert key.scopes == ["full"]
      assert DateTime.diff(key.expires_at, DateTime.utc_now()) > 29 * 24 * 3600
      assert {:ok, %{id: uid}, _} = Accounts.authenticate_api_key(token)
      assert uid == user.id

      events = Audit.list_recent_for_user(user.id, 20)
      authorized = Enum.find(events, &(&1.action == "oauth.authorized"))
      assert authorized.actor == "ui"
      assert authorized.request_ip == "9.9.9.9"
      assert authorized.resource_type == "oauth_client"
      assert authorized.metadata == %{"client_id" => @client, "redirect_uri" => @redirect}

      minted = Enum.find(events, &(&1.action == "api_key.created"))
      # The exchange has no session, so the mint's actor is the context default.
      assert minted.actor == "self"
      assert minted.request_ip == "9.9.9.9"
    end

    test "revoke/2 is revoking the API key" do
      user = insert_verified_user()
      {verifier, challenge} = pkce()
      {:ok, code} = OAuth.authorize(user.id, request(challenge))
      {:ok, %{access_token: token, api_key: key}} = exchange(code, verifier)

      assert {:ok, _} = OAuth.revoke(key, actor: "api")
      assert {:error, :revoked} = Accounts.authenticate_api_key(token)
      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "api_key.revoked" in actions
    end
  end

  test "an ordinary OAuth app completes PKCE without inheriting an admin's operator scope" do
    user = insert_verified_user(role: "admin")
    {verifier, challenge} = pkce()
    redirect = @redirect

    params =
      request(challenge)
      |> Map.merge(%{"client_id" => @client, "redirect_uri" => redirect})

    assert {:ok, _} = OAuth.validate_request(params, user.id)
    assert {:ok, code} = OAuth.authorize(user.id, params)

    assert {:ok, %{api_key: key}} =
             OAuth.exchange(%{
               "code" => code,
               "code_verifier" => verifier,
               "client_id" => @client,
               "redirect_uri" => redirect
             })

    assert key.scopes == ["full"]
    refute Accounts.ApiKey.admin?(key)
  end

  describe "a device grant mints an API key (#1305)" do
    test "named CLI login, no expiry, full scope — and audits the approval" do
      user = insert_verified_user()
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()

      assert :ok = OAuth.approve_device_grant(user_code, user.id, actor: "ui")

      assert {:ok, %{access_token: token, api_key: key}} =
               OAuth.poll_device_grant(device_code, actor: "api")

      assert key.name =~ "CLI login"
      assert key.scopes == ["full"]
      assert is_nil(key.expires_at)
      assert key.user_id == user.id
      assert {:ok, %{id: uid}, _} = Accounts.authenticate_api_key(token)
      assert uid == user.id

      events = Audit.list_recent_for_user(user.id, 20)
      approved = Enum.find(events, &(&1.action == "oauth.device_approved"))
      assert approved.actor == "ui"
      assert approved.resource_type == "oauth_device_grant"
      assert is_binary(approved.resource_id)
      assert Enum.find(events, &(&1.action == "api_key.created")).actor == "api"
    end

    test "a denial audits oauth.device_denied" do
      user = insert_verified_user()
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()

      assert :ok = OAuth.deny_device_grant(user_code, user.id, actor: "ui")
      assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "oauth.device_denied" in actions
    end

    test "an unverified approver cannot collect a key" do
      user = insert_user()
      assert is_nil(user.email_verified_at)
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      assert :ok = OAuth.approve_device_grant(user_code, user.id)

      assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)
    end
  end

  describe "Fountain.OAuth.Host" do
    test "subject_allowed?/1 answers for the three shapes of account" do
      assert :ok = Fountain.OAuth.Host.subject_allowed?(insert_verified_user().id)
      assert {:error, :not_eligible} = Fountain.OAuth.Host.subject_allowed?(insert_user().id)

      assert {:error, :unknown_subject} =
               Fountain.OAuth.Host.subject_allowed?(Ecto.UUID.generate())
    end
  end
end
