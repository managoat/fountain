defmodule FountainWeb.PrincipalInferenceCredentialTest do
  @moduledoc """
  An application puts a customer's inference key on a principal it opened
  (ADR 0053 decision 7).

  This is the gap that kept a business managing several end customers on one
  shared account. ADR 0044 already gives each customer a first-class tenant
  with its own DEK, its own audit trail and one invoice for the owner --
  `Principals.billing_subject_id/1` resolves a claimed principal to its owner
  -- but a `principal`-scoped key cannot write account state, so nothing could
  put the customer's key on the tenant that would use it.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.{Crypto, InferenceCredentials, Principals}

  setup do
    application = insert_verified_user()
    {_rec, key} = insert_api_key(application)

    {:ok, %{claimable: claimable, claim_token: claim_token}} =
      Principals.create_claimable(application, %{"application_id" => "test-app"})

    {:ok, application: application, key: key, claimable: claimable, claim_token: claim_token}
  end

  defp principal_path(claimable, provider),
    do: "/api/claimable-users/#{claimable.id}/inference-credentials/#{provider}"

  defp value_on(claimable, provider) do
    {:ok, dek} = Crypto.load_tenant_key(claimable.user_id)
    {:ok, creds} = InferenceCredentials.decrypted_for_user(claimable.user_id, dek)
    Map.get(creds, provider)
  end

  describe "the application that opened it" do
    test "stores the credential under the principal's own key", %{
      conn: conn,
      key: key,
      claimable: claimable
    } do
      assert conn
             |> authed_with_key(key)
             |> put_json(principal_path(claimable, "anthropic_api_key"), %{
               "value" => "sk-customer"
             })
             |> response(204)

      assert value_on(claimable, :anthropic_api_key) == "sk-customer"
    end

    # The principal's DEK, not the application's. Encrypting under the
    # operator's key would make the credential unreadable by the tenant that
    # has to run on it, and would put a customer's secret in the wrong
    # cryptographic tenant.
    test "the application cannot read it back with its own key", %{
      conn: conn,
      key: key,
      application: application,
      claimable: claimable
    } do
      conn
      |> authed_with_key(key)
      |> put_json(principal_path(claimable, "anthropic_api_key"), %{"value" => "sk-customer"})
      |> response(204)

      {:ok, app_dek} = Crypto.load_tenant_key(application.id)
      assert {:ok, %{}} == InferenceCredentials.decrypted_for_user(application.id, app_dek)
    end

    test "clears it again", %{conn: conn, key: key, claimable: claimable} do
      conn
      |> authed_with_key(key)
      |> put_json(principal_path(claimable, "openai_api_key"), %{"value" => "sk-open"})
      |> response(204)

      assert conn
             |> authed_with_key(key)
             |> delete(principal_path(claimable, "openai_api_key"))
             |> response(204)

      assert is_nil(value_on(claimable, :openai_api_key))
    end

    test "a blank value is 422 and stores nothing", %{conn: conn, key: key, claimable: claimable} do
      body =
        conn
        |> authed_with_key(key)
        |> put_json(principal_path(claimable, "anthropic_api_key"), %{"value" => "   "})
        |> json_response(422)

      assert body["reason"] == "empty_value"
      assert is_nil(value_on(claimable, :anthropic_api_key))
    end
  end

  describe "the account that claimed it" do
    test "may write too", %{conn: conn, claimable: claimable, claim_token: claim_token} do
      claimer = insert_verified_user()
      {_rec, claimer_key} = insert_api_key(claimer)

      {:ok, _} = Principals.claim(claimable.id, claim_token, claimer)

      assert conn
             |> authed_with_key(claimer_key)
             |> put_json(principal_path(claimable, "anthropic_api_key"), %{
               "value" => "sk-owner-set"
             })
             |> response(204)

      assert value_on(claimable, :anthropic_api_key) == "sk-owner-set"
    end
  end

  describe "everybody else" do
    test "a stranger's full-scope key is 404, not 403, and writes nothing", %{
      conn: conn,
      claimable: claimable
    } do
      stranger = insert_verified_user()
      {_rec, stranger_key} = insert_api_key(stranger)

      assert conn
             |> authed_with_key(stranger_key)
             |> put_json(principal_path(claimable, "anthropic_api_key"), %{
               "value" => "sk-not-yours"
             })
             |> json_response(404)

      assert is_nil(value_on(claimable, :anthropic_api_key))
    end

    test "an unknown grant id is the same 404", %{conn: conn, key: key} do
      fake = %{id: Ecto.UUID.generate()}

      assert conn
             |> authed_with_key(key)
             |> put_json(principal_path(fake, "anthropic_api_key"), %{"value" => "sk-nope"})
             |> json_response(404)
    end

    # The whole point of the route: the principal's own credential is outside
    # `@key_management_scopes`, so it cannot write account state -- including
    # its own inference credential.
    test "the principal's own key cannot use it", %{conn: conn, application: application} do
      {:ok, %{claimable: other, api_key: principal_key}} =
        Principals.create_claimable(application, %{"application_id" => "test-app-2"})

      assert conn
             |> authed_with_key(principal_key)
             |> put_json(principal_path(other, "anthropic_api_key"), %{"value" => "sk-self"})
             |> json_response(403)

      assert is_nil(value_on(other, :anthropic_api_key))
    end

    test "a sprite-scoped key cannot either", %{
      conn: conn,
      application: application,
      claimable: claimable
    } do
      {_rec, sprite_key} = insert_sprite_api_key(application)

      assert conn
             |> authed_with_key(sprite_key)
             |> put_json(principal_path(claimable, "anthropic_api_key"), %{
               "value" => "sk-sandbox"
             })
             |> json_response(403)

      assert is_nil(value_on(claimable, :anthropic_api_key))
    end
  end

  describe "the trail" do
    test "is the principal's, and names the account that acted", %{
      conn: conn,
      key: key,
      application: application,
      claimable: claimable
    } do
      conn
      |> authed_with_key(key)
      |> put_json(principal_path(claimable, "anthropic_api_key"), %{"value" => "sk-trailed"})
      |> response(204)

      event =
        claimable.user_id
        |> Fountain.Audit.list_recent_for_user(50)
        |> Enum.find(&(&1.action == "inference_credential.write"))

      assert event.user_id == claimable.user_id
      assert event.metadata["by_account"] == application.id
      assert event.metadata["provider"] == "anthropic_api_key"
      refute inspect(event) =~ "sk-trailed"
    end
  end
end
