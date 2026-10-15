defmodule Fountain.ConnectionsTest do
  @moduledoc """
  Connections (ADR 0085): connecting, the callback, holding and refreshing
  the tokens, letting go of them. The remote server and its authorization
  server are `Fountain.Connections.FakeProvider`, a `Req.Test` stub.
  """
  use Fountain.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Fountain.{Audit, Connections, Repo}
  alias Fountain.Connections.{Connection, FakeProvider}

  setup do
    {:ok, user: insert_verified_user(), provider: FakeProvider.stub()}
  end

  describe "create/3" do
    test "discovers, registers dynamically and stores a pending row", %{user: user} do
      assert {:ok, conn, url} =
               Connections.create(user.id, %{"url" => " https://mcp.example.com/mcp "},
                 actor: "api"
               )

      assert conn.status == "pending"
      assert conn.user_id == user.id
      assert conn.resource == "https://mcp.example.com/mcp"
      assert conn.registration == "dynamic"
      assert conn.client_id == "dyn-client"
      assert conn.token_endpoint == "https://token.example.com/token"
      assert is_binary(conn.login_verifier_ciphertext)

      q = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert q["client_id"] == "dyn-client"
      assert q["redirect_uri"] == Connections.redirect_uri()
      assert q["redirect_uri"] =~ ~r{/connections/callback$}
      assert q["resource"] == "https://mcp.example.com/mcp"
      assert q["code_challenge_method"] == "S256"

      assert [%{action: "connection.created", actor: "api", metadata: meta}] = events(user)
      assert meta["registration"] == "dynamic"
    end

    test "a pasted client wins, keeps its secret encrypted and its extra parameters", %{
      user: user
    } do
      assert {:ok, conn, url} =
               Connections.create(user.id, %{
                 "url" => FakeProvider.server_url(),
                 "client_id" => "mine",
                 "client_secret" => "shh-secret",
                 "authorize_params" => %{"access_type" => "offline", "prompt" => "consent"}
               })

      assert conn.registration == "pasted"
      assert conn.token_endpoint_auth_method == "client_secret_basic"
      refute conn.client_secret_ciphertext =~ "shh-secret"
      q = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert q["access_type"] == "offline"
      assert q["prompt"] == "consent"
      refute_received {:provider, "POST", _, "/register", _, _}
    end

    test "asks for a client when the server offers no registration", %{user: user} do
      FakeProvider.stub(registration: false, cimd: false)

      assert {:error, :client_required} =
               Connections.create(user.id, %{"url" => FakeProvider.server_url()})

      assert Connections.error_message(:client_required) =~ "/connections/callback"
      assert Connections.list(user.id) == []
    end

    test "refuses a second connection to the same resource, and bad input", %{user: user} do
      {:ok, conn, _} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
      id = conn.id

      assert {:error, {:connection_exists, ^id}} =
               Connections.create(user.id, %{"url" => FakeProvider.server_url()})

      assert {:error, :invalid_url} = Connections.create(user.id, %{"url" => "http://x.example"})

      assert {:error, :invalid_authorize_params} =
               Connections.create(user.id, %{
                 "url" => FakeProvider.server_url(),
                 "authorize_params" => %{"redirect_uri" => "https://evil.example"}
               })
    end
  end

  describe "complete/3" do
    test "the full flow: callback stores encrypted tokens, audited", %{user: user} do
      conn = connect!(user)
      assert conn.status == "active"
      assert conn.login_nonce == nil
      assert conn.login_verifier_ciphertext == nil
      refute conn.access_token_ciphertext =~ "access-1"
      assert %DateTime{} = conn.expires_at

      assert_received {:provider, "POST", "token.example.com", "/token",
                       %{"grant_type" => "authorization_code", "code" => "good-code"} = form, _}

      assert form["redirect_uri"] == Connections.redirect_uri()
      assert form["resource"] == "https://mcp.example.com/mcp"

      assert {:ok, "access-1", %DateTime{}} = Connections.token_for_session(user.id, conn.id)
      assert "connection.connected" in Enum.map(events(user), & &1.action)
    end

    test "refuses a state signed for another user", %{user: user} do
      {:ok, _conn, url} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
      other = insert_verified_user()

      assert {:error, :invalid_state} =
               Connections.complete(other.id, %{"state" => state(url), "code" => "good-code"})

      refute_received {:provider, "POST", "token.example.com", _, _, _}
    end

    test "refuses a superseded login, a provider error and a forged state", %{user: user} do
      {:ok, conn, first} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
      {:ok, _conn, _second} = Connections.authorize(user.id, conn.id)

      assert {:error, :stale_login} =
               Connections.complete(user.id, %{"state" => state(first), "code" => "good-code"})

      {:ok, _conn, third} = Connections.authorize(user.id, conn.id)

      assert {:error, {:provider, "access_denied"}} =
               Connections.complete(user.id, %{
                 "state" => state(third),
                 "error" => "access_denied"
               })

      assert {:error, :invalid_state} =
               Connections.complete(user.id, %{"state" => "forged", "code" => "good-code"})
    end

    test "checks iss where the server promised it", %{user: user} do
      FakeProvider.stub(iss: true)
      {:ok, _conn, url} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})

      assert {:error, :issuer_mismatch} =
               Connections.complete(user.id, %{"state" => state(url), "code" => "good-code"})

      assert {:error, :issuer_mismatch} =
               Connections.complete(user.id, %{
                 "state" => state(url),
                 "code" => "good-code",
                 "iss" => "https://evil.example.com"
               })

      # One trailing slash is ignored.
      assert {:ok, %Connection{status: "active"}} =
               Connections.complete(user.id, %{
                 "state" => state(url),
                 "code" => "good-code",
                 "iss" => "https://auth.example.com"
               })
    end

    test "a reconnect replaces the grant and revokes the old one at the provider", %{user: user} do
      conn = connect!(user)
      {:ok, _conn, url} = Connections.authorize(user.id, conn.id)
      drain()

      assert {:ok, %Connection{status: "active"}} =
               Connections.complete(user.id, %{"state" => state(url), "code" => "good-code"})

      assert_received {:provider, "POST", "auth.example.com", "/revoke",
                       %{"token" => "refresh-1", "token_type_hint" => "refresh_token"}, _}
    end
  end

  describe "tokens for a session" do
    test "refreshes a token that expires within ten minutes, rotating both", %{user: user} do
      FakeProvider.stub(expires_in: 120)
      conn = connect!(user)

      assert {:ok, "access-r" <> _, _} = Connections.token_for_session(user.id, conn.id)

      assert_received {:provider, "POST", "token.example.com", "/token",
                       %{"grant_type" => "refresh_token", "refresh_token" => "refresh-1"} = form,
                       _}

      assert form["resource"] == "https://mcp.example.com/mcp"
      stored = Repo.get!(Connection, conn.id)
      assert stored.refresh_lease_until == nil
      refute stored.refresh_token_ciphertext == conn.refresh_token_ciphertext
    end

    test "a terminal refusal revokes the connection", %{user: user} do
      FakeProvider.stub(expires_in: 120)
      conn = connect!(user)
      FakeProvider.stub(refresh_error: "invalid_grant")

      assert {:error, :connection_reconnect_required} =
               Connections.token_for_session(user.id, conn.id)

      assert %Connection{status: "revoked", revoked_reason: "invalid_grant"} =
               Repo.get!(Connection, conn.id)

      assert {:error, {:connection_reconnect_required, _}} =
               Connections.check_usable(user.id, conn.id)

      assert %{actor: "system:connection_refresh"} =
               Enum.find(events(user), &(&1.action == "connection.revoked"))
    end

    test "a transient refusal keeps the stored token", %{user: user} do
      FakeProvider.stub(expires_in: 120)
      conn = connect!(user)
      FakeProvider.stub(refresh_error: "temporarily_unavailable")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert {:ok, "access-1", _} = Connections.token_for_session(user.id, conn.id)
             end) =~ "refresh failed: 400 temporarily_unavailable"

      assert %Connection{status: "active", refresh_lease_until: nil} =
               Repo.get!(Connection, conn.id)
    end

    test "a lapsed token with no refresh token expires the connection", %{user: user} do
      FakeProvider.stub(refresh: false, expires_in: 3600)
      conn = connect!(user)
      assert :ok = Connections.check_usable(user.id, conn.id)

      Repo.update_all(from(c in Connection, where: c.id == ^conn.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -5) |> DateTime.truncate(:second)]
      )

      assert {:error, {:connection_reconnect_required, _}} =
               Connections.check_usable(user.id, conn.id)

      assert %Connection{status: "expired"} = Repo.get!(Connection, conn.id)
      assert "connection.expired" in Enum.map(events(user), & &1.action)

      assert {:error, :connection_reconnect_required} =
               Connections.token_for_session(user.id, conn.id)
    end

    test "a pending connection is not usable", %{user: user} do
      {:ok, conn, _} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})

      assert {:error, {:connection_reconnect_required, _}} =
               Connections.check_usable(user.id, conn.id)

      assert {:error, :connection_reconnect_required} =
               Connections.token_for_session(user.id, conn.id)
    end
  end

  describe "letting go" do
    test "delete removes the row, then revokes at the provider, audited", %{user: user} do
      conn = connect!(user)
      drain()

      assert :ok = Connections.delete(user.id, conn.id, actor: "ui")
      assert Repo.get(Connection, conn.id) == nil

      assert_received {:provider, "POST", "auth.example.com", "/revoke",
                       %{"token" => "refresh-1"}, _}

      assert %{actor: "ui", metadata: %{"provider" => "revoked"}} =
               Enum.find(events(user), &(&1.action == "connection.deleted"))
    end

    test "another user reaches nothing", %{user: user} do
      conn = connect!(user)
      other = insert_verified_user()

      assert Connections.get(conn.id, other.id) == nil
      assert Connections.list(other.id) == []
      assert {:error, :not_found} = Connections.delete(other.id, conn.id)
      assert {:error, :not_found} = Connections.authorize(other.id, conn.id)

      assert {:error, :connection_reconnect_required} =
               Connections.token_for_session(other.id, conn.id)

      assert Repo.get(Connection, conn.id)
    end

    test "account deletion revokes every grant after the delete", %{user: user} do
      conn = connect!(user)
      drain()

      grants = Connections.grants_to_end(user.id)
      assert [{id, _}] = grants
      assert id == conn.id
      Connections.end_grants_after_deletion(grants)

      assert_received {:provider, "POST", "auth.example.com", "/revoke",
                       %{"token" => "refresh-1"}, _}
    end
  end

  test "secret and binding keys may not take the reserved range", %{user: user} do
    assert Connections.reserved_key?(Connections.broker_key(Ecto.UUID.generate()))

    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

    cs =
      Fountain.Environments.Secret.changeset(
        %Fountain.Environments.Secret{},
        %{
          "key" => "MANAGOAT_CONNECTION_X",
          "value" => "v",
          "environment_id" => Ecto.UUID.generate()
        },
        dek
      )

    assert %{key: [msg]} = errors_on(cs)
    assert msg =~ "reserve"
  end

  test "the client ID metadata document names the one redirect URI" do
    doc = Connections.client_metadata()
    assert doc["client_id"] == Connections.client_id_metadata_url()
    assert doc["redirect_uris"] == [Connections.redirect_uri()]
    assert doc["token_endpoint_auth_method"] == "none"
  end

  defp connect!(user) do
    {:ok, _pending, url} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})

    {:ok, conn} =
      Connections.complete(user.id, %{"state" => state(url), "code" => "good-code"}, actor: "ui")

    assert conn.id
    conn
  end

  defp state(url),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

  defp events(user) do
    user.id
    |> Audit.list_recent_for_user(100)
    |> Enum.filter(&String.starts_with?(&1.action, "connection."))
  end

  defp drain do
    receive do
      {:provider, _, _, _, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end
