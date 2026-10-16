defmodule Fountain.EnvironmentLayers.StoreTest do
  use Fountain.DataCase, async: true

  alias Fountain.EnvironmentLayers.Store
  alias Fountain.EnvironmentLayers.Store.Config

  defp config do
    %Config{
      endpoint: "https://fly.storage.tigris.dev",
      bucket: "private-layers",
      access_key_id: "test-access-id",
      secret_access_key: "test-secret-value"
    }
  end

  setup do
    user = insert_verified_user()
    env = insert_env(%{user_id: user.id})
    %{user: user, env: env, artifact: Ecto.UUID.generate()}
  end

  test "disabled storage grants nothing", %{user: user, env: env, artifact: artifact} do
    assert {:error, :disabled} = Store.grant(user.id, env.id, artifact, :get, config: nil)
  end

  test "capabilities are scoped, time bounded, method bound and redacted", context do
    %{user: user, env: env, artifact: artifact} = context
    now = ~U[2026-10-16 12:00:00Z]

    grants =
      for method <- [:get, :put, :delete] do
        assert {:ok, grant} =
                 Store.grant(user.id, env.id, artifact, method, config: config(), now: now)

        uri = URI.parse(grant.url)
        query = URI.decode_query(uri.query)

        assert uri.path ==
                 "/private-layers/environment-layers/v1/#{user.id}/#{env.id}/#{artifact}.age"

        assert query["X-Amz-Expires"] == "300"
        assert query["X-Amz-SignedHeaders"] == "host"
        assert query["X-Amz-Date"] == "20261016T120000Z"
        assert query["X-Amz-Credential"] == "test-access-id/20261016/auto/s3/aws4_request"
        assert grant.expires_at == ~U[2026-10-16 12:05:00Z]
        refute inspect(grant) =~ "X-Amz"
        refute grant.url =~ "test-secret-value"
        query["X-Amz-Signature"]
      end

    assert length(Enum.uniq(grants)) == 3
    refute inspect(config()) =~ "test-secret-value"
    refute inspect(config()) =~ "test-access-id"
  end

  test "foreign, deleted and malformed environments cannot obtain grants", context do
    other = insert_verified_user()
    %{user: user, env: env, artifact: artifact} = context

    assert {:error, :not_found} = Store.grant(other.id, env.id, artifact, :get, config: config())

    assert {:error, :not_found} =
             Store.grant(user.id, Ecto.UUID.generate(), artifact, :get, config: config())

    assert {:error, :invalid_reference} =
             Store.grant(user.id, "../other", artifact, :get, config: config())

    assert {:error, :invalid_reference} =
             Store.grant(user.id, env.id, "../other", :get, config: config())
  end

  test "rejects unsafe configuration, unbounded expiry and unsupported methods", context do
    %{user: user, env: env, artifact: artifact} = context

    for endpoint <- [
          "http://store.example",
          "https://store.example:notaport",
          "https://store.example:0",
          "https://store.example:65536",
          "https://store.example with spaces",
          "https://user:pass@store.example",
          "https://store.example/path",
          "https://store.example?query=1",
          "https://store.example/#fragment"
        ] do
      assert {:error, :invalid_store} =
               Store.grant(user.id, env.id, artifact, :get,
                 config: %{config() | endpoint: endpoint}
               )
    end

    for bucket <- ["../other", "bucket/key", "bucket?query", "bucket..other"] do
      assert {:error, :invalid_store} =
               Store.grant(user.id, env.id, artifact, :get, config: %{config() | bucket: bucket})
    end

    for expires <- [0, -1, 901, "300"] do
      assert {:error, :invalid_expiry} =
               Store.grant(user.id, env.id, artifact, :get, config: config(), expires: expires)
    end

    assert {:error, :invalid_operation} =
             Store.grant(user.id, env.id, artifact, :list, config: config())
  end

  test "temporary credentials are included in the signature without being inspectable", context do
    %{user: user, env: env, artifact: artifact} = context
    cfg = %{config() | session_token: "temporary+token/value"}
    assert {:ok, grant} = Store.grant(user.id, env.id, artifact, :get, config: cfg)

    assert URI.decode_query(URI.parse(grant.url).query)["X-Amz-Security-Token"] ==
             cfg.session_token

    refute inspect(grant) =~ "temporary"
    refute inspect(cfg) =~ "temporary"
  end
end
