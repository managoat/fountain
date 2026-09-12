defmodule FountainWeb.InferenceCredentialInSetTest do
  @moduledoc """
  Writing a provider credential into a **named** set (ADR 0053 decision 1).

  Without this a second set can only ever be empty, so this is the route that
  makes the whole feature usable: it is where a tenant's second Claude
  subscription goes, and what an agent then points at.

  The same validate-then-store path as the default-set write, on the same
  controller, so the three provider-ping outcomes cannot drift apart.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Crypto, InferenceCredentials}

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    {:ok, default} = InferenceCredentials.create_set(user.id, "Default")
    {:ok, second} = InferenceCredentials.create_set(user.id, "Second subscription")
    {:ok, user: user, key: key, default: default, second: second}
  end

  defp ping_ok, do: stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)

  defp value_in(set, provider) do
    {:ok, dek} = Crypto.load_tenant_key(set.user_id)
    {:ok, creds} = InferenceCredentials.decrypted_for_set(Fountain.Repo.reload!(set), dek)
    Map.get(creds, provider)
  end

  defp credential_path(set, provider),
    do: "/api/account/inference-credential-sets/#{set.id}/credentials/#{provider}"

  describe "PUT a credential into a named set" do
    test "lands in that set and nowhere else", %{
      conn: conn,
      key: key,
      default: default,
      second: second
    } do
      ping_ok()

      body =
        conn
        |> authed_with_key(key)
        |> put_json(credential_path(second, "anthropic_api_key"), %{"value" => "sk-ant-second"})
        |> json_response(200)

      assert body["data"] == %{"provider" => "anthropic_api_key", "set" => true}
      assert value_in(second, :anthropic_api_key) == "sk-ant-second"
      assert is_nil(value_in(default, :anthropic_api_key))
    end

    test "the response reports the set it wrote, not the account default", %{
      conn: conn,
      key: key,
      default: default,
      second: second
    } do
      ping_ok()

      {:ok, dek} = Crypto.load_tenant_key(default.user_id)
      {:ok, _} = InferenceCredentials.put_credential_in(default, dek, :openai_api_key, "sk-open")

      body =
        conn
        |> authed_with_key(key)
        |> put_json(credential_path(second, "anthropic_api_key"), %{"value" => "sk-ant-second"})
        |> json_response(200)

      # The default set holds an OpenAI key; this response is about the set
      # that was written, so it says nothing about that.
      assert body["data"]["provider"] == "anthropic_api_key"
    end

    test "never returns the value", %{conn: conn, key: key, second: second} do
      ping_ok()

      conn =
        conn
        |> authed_with_key(key)
        |> put_json(credential_path(second, "anthropic_api_key"), %{
          "value" => "sk-ant-very-secret"
        })

      refute conn.resp_body =~ "sk-ant-very-secret"
    end

    test "validate: false skips the ping", %{conn: conn, key: key, second: second} do
      # No Req stub at all: a ping here would raise.
      assert conn
             |> authed_with_key(key)
             |> put_json(credential_path(second, "gemini_api_key"), %{
               "value" => "AIza-unchecked",
               "validate" => false
             })
             |> json_response(200)

      assert value_in(second, :gemini_api_key) == "AIza-unchecked"
    end

    test "a rejected credential is 422 and stores nothing", %{
      conn: conn,
      key: key,
      second: second
    } do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 401}} end)

      body =
        conn
        |> authed_with_key(key)
        |> put_json(credential_path(second, "anthropic_api_key"), %{"value" => "sk-wrong"})
        |> json_response(422)

      assert body["reason"] == "invalid"
      assert is_nil(value_in(second, :anthropic_api_key))
    end

    test "another tenant's set is 404, and writes nothing", %{conn: conn, key: key} do
      ping_ok()
      other = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other.id, "Theirs")

      assert conn
             |> authed_with_key(key)
             |> put_json(credential_path(theirs, "anthropic_api_key"), %{
               "value" => "sk-not-yours"
             })
             |> json_response(404)

      assert is_nil(value_in(theirs, :anthropic_api_key))
    end

    test "a sprite-scoped key cannot write into a set either", %{user: user, second: second} do
      {_rec, raw} = insert_sprite_api_key(user)

      assert build_conn()
             |> authed_with_key(raw)
             |> put_json(credential_path(second, "anthropic_api_key"), %{
               "value" => "sk-from-a-sandbox"
             })
             |> json_response(403)

      assert is_nil(value_in(second, :anthropic_api_key))
    end
  end

  describe "DELETE a credential from a named set" do
    test "clears that set and leaves the others alone", %{
      conn: conn,
      key: key,
      default: default,
      second: second
    } do
      {:ok, dek} = Crypto.load_tenant_key(default.user_id)
      {:ok, _} = InferenceCredentials.put_credential_in(default, dek, :anthropic_api_key, "sk-d")
      {:ok, _} = InferenceCredentials.put_credential_in(second, dek, :anthropic_api_key, "sk-s")

      assert conn
             |> authed_with_key(key)
             |> delete(credential_path(second, "anthropic_api_key"))
             |> response(204)

      assert is_nil(value_in(second, :anthropic_api_key))
      assert value_in(default, :anthropic_api_key) == "sk-d"
    end

    test "another tenant's set is 404", %{conn: conn, key: key} do
      other = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other.id, "Theirs")

      assert conn
             |> authed_with_key(key)
             |> delete(credential_path(theirs, "anthropic_api_key"))
             |> json_response(404)
    end
  end

  describe "the trail" do
    # The provider alone answered "what changed" while an account held one
    # row. With several it does not, and a trail that cannot say which key
    # moved cannot explain the turn that ran on it.
    test "records which set the credential landed in, and never the value", %{
      conn: conn,
      key: key,
      user: user,
      second: second
    } do
      ping_ok()

      conn
      |> authed_with_key(key)
      |> put_json(credential_path(second, "anthropic_api_key"), %{"value" => "sk-ant-trailed"})
      |> json_response(200)

      event =
        user.id
        |> Fountain.Audit.list_recent_for_user(50)
        |> Enum.find(&(&1.action == "inference_credential.write"))

      assert event.metadata["set_id"] == second.id
      assert event.metadata["set"] == "Second subscription"
      assert event.metadata["provider"] == "anthropic_api_key"
      refute inspect(event) =~ "sk-ant-trailed"
    end
  end
end
