defmodule Fountain.PlatformChatGPTTest do
  @moduledoc """
  The deployment's ChatGPT grant for codex (ADR 0047): connect, the locked
  refresh and its terminal refusal, the workspace token, the keepalive, and
  the two places the grant reaches a conversation — `select/3` and the
  per-turn re-read.

  `async: false`: there is one platform row and one advisory lock, and both
  are shared across every test that connects a grant; an async module would
  block on another's uncommitted row. The selection tests also write the
  platform key into the application environment (#1214).
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]
  import Fountain.ChatGPTFixtures

  alias Fountain.Audit.AdminEvent
  alias Fountain.Broker
  alias Fountain.ChatGPTAccounts
  alias Fountain.Conversations.Egress
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.PlatformInference
  alias Fountain.Repo

  setup do
    original = Application.get_env(:fountain, :platform_openai_api_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fountain, :platform_openai_api_key)
        value -> Application.put_env(:fountain, :platform_openai_api_key, value)
      end
    end)

    # Nothing in these tests should reach the auth server unless a test says
    # so; a stub that raises makes a stray call a failure, not a hang.
    stub_auth(%{})
    :ok
  end

  defp events(type) do
    Repo.all(from e in AdminEvent, where: e.event_type == ^type, order_by: e.id)
  end

  defp row, do: Repo.one!(Account)

  # What the sandbox file is built from, pinned to the deployment's grant as a
  # conversation selected onto it would pin it. `:none` with no grant.
  defp platform_sandbox_auth do
    case Repo.one(Account) do
      nil ->
        :none

      row ->
        ChatGPTAccounts.sandbox_auth(%{
          owner: :platform,
          grant_id: row.id,
          generation: row.generation
        })
    end
  end

  # The grant is selected only on a brokered deployment, a deployment fact
  # (`Fountain.Broker.configured?/0`); these set it the way the egress tests do.
  defp broker_on do
    restore_broker_on_exit()
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
  end

  defp broker_off do
    restore_broker_on_exit()
    Application.delete_env(:fountain, :broker_listen_port)
    Application.delete_env(:fountain, :broker_proxy_url)
  end

  defp restore_broker_on_exit do
    previous =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)
  end

  defp decrypt!(cipher) do
    {:ok, value} = Crypto.decrypt_platform(cipher)
    value
  end

  describe "platform_connect_from_auth_json/2" do
    test "stores the grant, the claims and nothing secret on the trail" do
      admin = insert_verified_user()
      access = access_token(3_600)

      assert {:ok, %Account{} = account} =
               ChatGPTAccounts.platform_connect_from_auth_json(
                 auth_json(%{access_token: access, refresh_token: "rt_secret"}),
                 actor_user_id: admin.id
               )

      assert account.kind == "chatgpt"
      assert account.status == "active"
      assert account.account_id == "acct_platform_1"
      assert account.account_email == "admin@example.com"
      assert account.plan_type == "pro"

      assert account.id_claims == %{
               "account_id" => "acct_platform_1",
               "user_id" => "user_1",
               "plan_type" => "pro"
             }

      assert is_nil(account.user_id)
      assert account.updated_by_user_id == admin.id
      assert DateTime.diff(account.access_expires_at, DateTime.utc_now(), :second) in 3_500..3_600
      assert decrypt!(account.refresh_token_ciphertext) == "rt_secret"
      assert decrypt!(account.access_token_ciphertext) == access

      assert [event] = events("admin.platform_chatgpt.connected")
      assert event.actor_user_id == admin.id
      assert event.metadata["method"] == "paste"
      assert event.metadata["email"] == "admin@example.com"
      assert event.metadata["plan"] == "pro"
      refute inspect(event.metadata) =~ "rt_secret"
      refute inspect(event.metadata) =~ access

      assert ChatGPTAccounts.platform_active?()
      assert ChatGPTAccounts.platform_access_token() == {:ok, access}

      assert %{status: "active", account_email: "admin@example.com"} =
               ChatGPTAccounts.platform_status()
    end

    test "a reconnect replaces the row rather than adding one" do
      connect!(%{refresh_token: "rt_one"})
      connect!(%{refresh_token: "rt_two", email: "other@example.com"})

      assert [account] = Repo.all(Account)
      assert decrypt!(account.refresh_token_ciphertext) == "rt_two"
      assert account.account_email == "other@example.com"
      assert length(events("admin.platform_chatgpt.connected")) == 2
    end

    test "refuses an API-key login, a file without a refresh token, and non-JSON" do
      assert {:error, :not_a_chatgpt_login} =
               ChatGPTAccounts.platform_connect_from_auth_json(auth_json(%{auth_mode: "apiKey"}))

      assert {:error, :no_refresh_token} =
               ChatGPTAccounts.platform_connect_from_auth_json(auth_json(%{refresh_token: ""}))

      assert {:error, :invalid_auth_json} =
               ChatGPTAccounts.platform_connect_from_auth_json("not json")

      assert {:error, :invalid_auth_json} = ChatGPTAccounts.platform_connect_from_auth_json("{}")

      # No account id in the id_token: codex would have nothing to send.
      assert {:error, :invalid_id_token} =
               ChatGPTAccounts.platform_connect_from_auth_json(
                 auth_json(%{id_token: jwt(%{"email" => "x"})})
               )

      refute ChatGPTAccounts.platform_active?()
      assert events("admin.platform_chatgpt.connected") == []
    end
  end

  describe "platform_access_token/0" do
    test "not connected, then served from the row without a refresh while fresh" do
      assert ChatGPTAccounts.platform_access_token() == {:error, :not_connected}
      assert ChatGPTAccounts.platform_selection() == :none

      access = access_token(3_600)
      connect!(%{access_token: access})
      assert ChatGPTAccounts.platform_access_token() == {:ok, access}
    end

    test "selection answers from the row and never dials out" do
      broker_on()
      stale = access_token(60)
      connect!(%{access_token: stale})
      user = insert_verified_user()

      # Selection hands out which grant, as its placeholder, never the token.
      placeholder = ChatGPTAccounts.Reserved.placeholder(row().id)

      assert ChatGPTAccounts.platform_selection() ==
               {:ok, %{grant_id: row().id, generation: row().generation}}

      assert {:ok, %Source{scope: :platform}, %{codex_chatgpt_access_token: ^placeholder}} =
               InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

      # No stub for /oauth/token until here: a refresh above would have
      # raised, and the token inside its margin is still the one stored.
      assert decrypt!(row().access_token_ciphertext) == stale

      stub_refusal()
      assert ChatGPTAccounts.platform_access_token() == {:error, :revoked}
      assert ChatGPTAccounts.platform_selection() == :none
    end

    test "refreshes within the margin, persists the rotated refresh token, then serves the new one" do
      connect!(%{access_token: access_token(60), refresh_token: "rt_original"})
      new_access = access_token(7_200, %{"n" => 2})
      stub_refresh(%{access_token: new_access, refresh_token: "rt_rotated"})

      assert ChatGPTAccounts.platform_access_token() == {:ok, new_access}

      account = row()
      assert decrypt!(account.refresh_token_ciphertext) == "rt_rotated"
      assert decrypt!(account.access_token_ciphertext) == new_access
      assert DateTime.diff(account.access_expires_at, DateTime.utc_now(), :second) > 7_000
      assert account.status == "active"

      # The second call is served from the row: a stub that only accepts the
      # original refresh token would answer `refresh_token_reused` otherwise.
      assert ChatGPTAccounts.platform_access_token() == {:ok, new_access}
      assert events("admin.platform_chatgpt.revoked") == []
    end

    test "a terminal refusal marks the grant revoked with the server's reason" do
      connect!(%{access_token: access_token(60)})
      stub_refusal("refresh_token_reused")

      assert ChatGPTAccounts.platform_access_token() == {:error, :revoked}
      assert %Account{status: "revoked", revoked_reason: "refresh_token_reused"} = row()
      assert ChatGPTAccounts.platform_selection() == :none
      refute ChatGPTAccounts.platform_active?()

      assert %{status: "revoked", revoked_reason: "refresh_token_reused"} =
               ChatGPTAccounts.platform_status()

      assert [event] = events("admin.platform_chatgpt.revoked")
      assert is_nil(event.actor_user_id)
      assert event.metadata["actor"] == "system:platform_chatgpt"
      assert event.metadata["reason"] == "refresh_token_reused"

      # Revoked stays revoked: no second round-trip, no second event.
      assert ChatGPTAccounts.platform_access_token() == {:error, :revoked}
      assert length(events("admin.platform_chatgpt.revoked")) == 1

      # The sandbox file's claims are still served: the file holds a
      # placeholder, and a revoke landing mid-provision must not fail the
      # spawn whose token the broker already took.
      assert {:ok, %{account_id: "acct_platform_1"}} = platform_sandbox_auth()
    end

    test "a bare invalid_grant is terminal too" do
      connect!(%{access_token: access_token(60)})
      stub_auth(%{"/oauth/token" => fn _ -> {400, %{"error" => "invalid_grant"}} end})

      assert ChatGPTAccounts.platform_access_token() == {:error, :revoked}
      assert row().revoked_reason == "invalid_grant"
    end

    test "a transient failure keeps the row and the old token" do
      access = access_token(60)
      connect!(%{access_token: access, refresh_token: "rt_original"})
      stub_auth(%{"/oauth/token" => fn _ -> {503, %{"error" => "try_later"}} end})

      assert {:error, {:token, 503, "try_later"}} = ChatGPTAccounts.platform_access_token()

      account = row()
      assert account.status == "active"
      assert decrypt!(account.refresh_token_ciphertext) == "rt_original"
      assert decrypt!(account.access_token_ciphertext) == access
      assert events("admin.platform_chatgpt.revoked") == []
    end
  end

  describe "platform_connect_workspace_token/3" do
    test "an opaque token with an admin-set expiry is served until it lapses, then expires" do
      admin = insert_verified_user()

      assert {:ok, account} =
               ChatGPTAccounts.platform_connect_workspace_token(
                 "wst_opaque_token",
                 ~D[2030-01-01],
                 actor_user_id: admin.id,
                 account_id: "acct_ws"
               )

      assert account.kind == "workspace_token"
      assert is_nil(account.refresh_token_ciphertext)
      assert account.account_id == "acct_ws"
      assert account.access_expires_at == ~U[2030-01-01 23:59:59Z]
      assert ChatGPTAccounts.platform_access_token() == {:ok, "wst_opaque_token"}
      assert %{kind: "workspace_token", status: "active"} = ChatGPTAccounts.platform_status()

      assert [event] = events("admin.platform_chatgpt.connected")
      assert event.metadata["method"] == "workspace_token"
      refute inspect(event.metadata) =~ "wst_opaque"

      # Lapsed: the row goes expired with a system event, once.
      row()
      |> Ecto.Changeset.change(access_expires_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      assert ChatGPTAccounts.platform_access_token() == {:error, :expired}
      assert %Account{status: "expired"} = row()
      assert [expired] = events("admin.platform_chatgpt.expired")
      assert expired.metadata["actor"] == "system:platform_chatgpt"
      assert ChatGPTAccounts.platform_access_token() == {:error, :expired}
      assert length(events("admin.platform_chatgpt.expired")) == 1
      assert ChatGPTAccounts.platform_selection() == :none
    end

    test "a JWT-shaped token supplies its own account id and expiry" do
      token =
        access_token(3_600, %{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_jwt"}
        })

      assert {:ok, account} = ChatGPTAccounts.platform_connect_workspace_token(token, nil)
      assert account.account_id == "acct_jwt"
      assert DateTime.diff(account.access_expires_at, DateTime.utc_now(), :second) > 3_000
    end

    test "an opaque token needs an account id: codex sends it on every request" do
      assert {:error, :no_account_id} =
               ChatGPTAccounts.platform_connect_workspace_token("wst_opaque", nil)

      assert {:error, :no_account_id} =
               ChatGPTAccounts.platform_connect_workspace_token("wst_opaque", nil,
                 account_id: "  "
               )

      refute ChatGPTAccounts.platform_active?()
      assert platform_sandbox_auth() == :none

      assert {:ok, _} =
               ChatGPTAccounts.platform_connect_workspace_token("wst_opaque", nil,
                 account_id: " acct_x "
               )

      assert {:ok, %{account_id: "acct_x"}} = platform_sandbox_auth()
    end

    test "refuses a blank, a whitespace-bearing, or an oversized value" do
      assert {:error, :invalid_token} = ChatGPTAccounts.platform_connect_workspace_token("", nil)

      assert {:error, :invalid_token} =
               ChatGPTAccounts.platform_connect_workspace_token("a b", nil)

      assert {:error, :invalid_token} =
               ChatGPTAccounts.platform_connect_workspace_token(String.duplicate("x", 9_000), nil)

      refute ChatGPTAccounts.platform_active?()
    end
  end

  describe "platform_disconnect/1" do
    test "removes the row and records once" do
      admin = insert_verified_user()
      connect!()

      assert :ok = ChatGPTAccounts.platform_disconnect(actor_user_id: admin.id)
      assert ChatGPTAccounts.platform_status() == :not_connected
      assert Repo.all(Account) == []

      assert :ok = ChatGPTAccounts.platform_disconnect(actor_user_id: admin.id)
      assert [event] = events("admin.platform_chatgpt.disconnected")
      assert event.actor_user_id == admin.id
      assert event.metadata["account_id"] == "acct_platform_1"
    end
  end

  describe "sandbox_auth/1 for the deployment's grant" do
    test "is the real account id and an unsigned id_token with the three claims and no email" do
      assert platform_sandbox_auth() == :none
      connect!()

      assert {:ok, %{account_id: "acct_platform_1", id_token: id_token}} =
               platform_sandbox_auth()

      assert [header, payload, signature] = String.split(id_token, ".")
      assert signature != ""
      assert Base.url_decode64!(header, padding: false) == ~s({"alg":"none"})

      claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert claims == %{
               "https://api.openai.com/auth" => %{
                 "chatgpt_account_id" => "acct_platform_1",
                 "chatgpt_user_id" => "user_1",
                 "chatgpt_plan_type" => "pro"
               }
             }

      # And it is what codex would read back out of it.
      assert {:ok, %{"account_id" => "acct_platform_1", "email" => nil}} =
               Fountain.PlatformChatGPT.Tokens.claims(id_token)
    end
  end

  describe "platform_keepalive/0" do
    test "skips when not connected, recently renewed, or a workspace token" do
      assert ChatGPTAccounts.platform_keepalive() == {:ok, :skipped}

      connect!()
      assert ChatGPTAccounts.platform_keepalive() == {:ok, :skipped}

      {:ok, _} =
        ChatGPTAccounts.platform_connect_workspace_token("wst_static", nil, account_id: "acct_ws")

      row()
      |> Ecto.Changeset.change(last_refreshed_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      assert ChatGPTAccounts.platform_keepalive() == {:ok, :skipped}
    end

    test "renews a grant older than the keepalive window whatever the access token says" do
      access = access_token(30 * 24 * 3_600)
      connect!(%{access_token: access})
      stub_refresh(%{refresh_token: "rt_kept_alive"})

      row()
      |> Ecto.Changeset.change(
        last_refreshed_at:
          DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert ChatGPTAccounts.platform_keepalive() == {:ok, :refreshed}
      account = row()
      assert decrypt!(account.refresh_token_ciphertext) == "rt_kept_alive"
      assert DateTime.diff(DateTime.utc_now(), account.last_refreshed_at, :second) < 60

      # The worker is the same call on a schedule.
      assert :ok = perform_job(Fountain.Workers.PlatformChatGPTKeepalive, %{})
    end

    test "reports a refusal and leaves the row revoked" do
      connect!()
      stub_refusal("refresh_token_invalidated")

      row()
      |> Ecto.Changeset.change(last_refreshed_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      assert ChatGPTAccounts.platform_keepalive() == {:error, :revoked}
      assert row().revoked_reason == "refresh_token_invalidated"
      assert :ok = perform_job(Fountain.Workers.PlatformChatGPTKeepalive, %{})
    end
  end

  defp resolve(user, model, runtime),
    do: InferenceCredentials.resolve(user.id, model, runtime, [])

  describe "InferenceCredentials.resolve/4 (ADR 0047 decision 6)" do
    setup do
      user = insert_verified_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      %{user: user, dek: dek}
    end

    test "a codex agent with no tenant key takes the grant, at :platform", %{user: user, dek: dek} do
      broker_on()
      access = access_token()
      grant = connect!(%{access_token: access})
      placeholder = ChatGPTAccounts.Reserved.placeholder(grant.id)

      # What the runtime is handed is the grant's placeholder: the bearer
      # never enters a conversation (ADR 0052 decision 6).
      assert {:ok, %Source{scope: :platform, kind: :codex_chatgpt_access_token} = source, creds} =
               resolve(user, "openai/gpt-5.5-codex", "codex")

      assert creds == %{codex_chatgpt_access_token: placeholder}
      refute inspect(creds) =~ access
      assert Source.grant_ref(source) == {:platform, grant.id, grant.generation}

      # The tenant's other credentials survive the merge.
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-ant")

      assert {:ok, %Source{scope: :platform},
              %{anthropic_api_key: "sk-ant", codex_chatgpt_access_token: ^placeholder}} =
               resolve(user, "openai/gpt-5.5-codex", "codex")
    end

    test "an unbrokered deployment never takes the grant: the token would land in the sandbox",
         %{user: user} do
      broker_off()
      connect!()

      assert {:ok, %Source{scope: :missing}, %{}} =
               resolve(user, "openai/gpt-5.5-codex", "codex")

      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key},
              %{openai_api_key: "sk-platform"}} = resolve(user, "openai/gpt-5.5-codex", "codex")
    end

    test "the tenant's own OpenAI key always wins", %{user: user, dek: dek} do
      broker_on()
      connect!()
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-mine")

      assert {:ok, %Source{scope: :credential}, %{openai_api_key: "sk-mine"}} =
               resolve(user, "openai/gpt-5.5-codex", "codex")
    end

    test "opencode on an openai model never takes the grant", %{user: user} do
      broker_on()
      connect!()

      assert {:ok, %Source{scope: :missing}, %{}} =
               resolve(user, "openai/gpt-5.5", "opencode")

      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key},
              %{openai_api_key: "sk-platform"}} = resolve(user, "openai/gpt-5.5", "opencode")

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key},
              %{openai_api_key: "sk-platform"}} = resolve(user, "openai/gpt-5.5", nil)
    end

    # The resolver never dials out, so the refusal is met where a turn meets
    # it, in the refresh before the turn; the row is `revoked` after that.
    test "a revoked grant falls through to the platform key, and to nothing", %{user: user} do
      broker_on()
      connect!(%{access_token: access_token(60)})
      stub_refusal()
      assert ChatGPTAccounts.platform_access_token() == {:error, :revoked}
      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      assert {:ok, %Source{scope: :platform, kind: :openai_api_key},
              %{openai_api_key: "sk-platform"}} = resolve(user, "openai/gpt-5.5-codex", "codex")

      Application.delete_env(:fountain, :platform_openai_api_key)

      assert {:ok, %Source{scope: :missing}, %{}} =
               resolve(user, "openai/gpt-5.5-codex", "codex")
    end

    test "the ceiling gate counts the grant as platform-served" do
      user = insert_verified_user()

      assert {:ok, %Source{scope: :missing} = source, _} =
               InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

      assert :ok = PlatformInference.gate_source(source)

      # The grant is selected only on a brokered deployment (decision 4 of
      # the selection order): configure one, as the egress tests do.
      broker_on()
      connect!()

      assert {:ok, %Source{scope: :platform, kind: :codex_chatgpt_access_token} = source, _} =
               InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

      # With credits off the ceiling never trips, so the gate is :ok.
      assert :ok = PlatformInference.gate_source(source)
    end
  end

  describe "the broker and the per-turn re-read (decisions 4 and 5)" do
    test "split_inference/2 takes no custody of the grant: it is not an inference key at all" do
      grant = connect!()
      placeholder = ChatGPTAccounts.Reserved.placeholder(grant.id)

      assert {creds, brokered, implicit} =
               Broker.split_inference(%{
                 codex_chatgpt_access_token: placeholder,
                 anthropic_api_key: "sk-ant"
               })

      assert creds.codex_chatgpt_access_token == placeholder
      assert brokered == %{"ANTHROPIC_API_KEY" => "sk-ant"}
      assert Map.keys(implicit) == ["ANTHROPIC_API_KEY"]
      refute Map.has_key?(Broker.inference_keys(), "CODEX_CHATGPT_ACCESS_TOKEN")
    end

    # ADR 0047 decision 5 as it now stands: rotation reaches a running
    # conversation through the grant row, not through a rewrite of its rules,
    # and nothing compares a token to decide which conversation is on the grant.
    test "the turn's gate renews the grant by itself, and hands nothing back" do
      broker_on()
      old = access_token(60)
      connect!(%{access_token: old})
      new_access = access_token(7_200, %{"n" => 2})
      stub_refresh(%{access_token: new_access})
      user = insert_verified_user()

      {:ok, source, _} =
        InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

      assert :ok = Fountain.Conversations.CodexChatGPT.ensure_fresh(user.id, source)
      assert decrypt!(row().access_token_ciphertext) == new_access

      # Fresh now: a second exchange would be refused as a reused refresh token.
      assert :ok = Fountain.Conversations.CodexChatGPT.ensure_fresh(user.id, source)
      assert decrypt!(row().access_token_ciphertext) == new_access
    end

    test "a renewal that fails, or a grant gone revoked, does not stop the turn at the gate" do
      broker_on()
      connect!(%{access_token: access_token(60)})
      user = insert_verified_user()

      {:ok, source, _} =
        InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

      assert :ok = InferenceCredentials.validate_source(user.id, source)

      stub_refusal()
      assert :ok = Fountain.Conversations.CodexChatGPT.ensure_fresh(user.id, source)
      assert %Account{status: "revoked"} = row()

      # The proxy refuses it, by name: no credential for a revoked grant.
      ref = Fountain.Conversations.CodexChatGPT.managed_grant(source, user.id)
      assert {:error, :denied} = ChatGPTAccounts.protected_credential(ref, "acct_platform_1")

      # And the next validation sees the change.
      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, source)
    end

    test "refresh_before_turn/1 leaves a conversation on the grant alone across a rotation" do
      broker_on()
      old = access_token(60)
      connect!(%{access_token: old})
      user = insert_verified_user()

      {:ok, source, creds} =
        InferenceCredentials.resolve(user.id, "openai/gpt-5.5-codex", "codex", [])

      {:ok, dek} = Crypto.load_tenant_key(user.id)

      session = %{
        vault: "c-test",
        token: "fb_live",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      }

      state = %{
        conversation_id: Ecto.UUID.generate(),
        user_id: user.id,
        tenant_key: dek,
        broker: session,
        brokered: %{},
        tenant_keys: [],
        connection_keys: [],
        secret_sources: nil,
        broker_bindings: %{},
        inference_credentials: creds,
        inference_source: source,
        inference_model: "openai/gpt-5.5-codex",
        broker_network: :unrestricted,
        sprite_env: []
      }

      # The rotation the previous release answered by rewriting the rules.
      new_access = access_token(7_200, %{"n" => 2})
      stub_refresh(%{access_token: new_access})
      assert :ok = ChatGPTAccounts.platform_ensure_fresh()
      assert decrypt!(row().access_token_ciphertext) == new_access

      stub(Broker, :refresh, fn _, _, _, _ -> flunk("a rotated grant rewrites no rule") end)
      stub(Broker, :prepare, fn _, _, _, _ -> flunk("a rotated grant mints no session") end)

      assert {next, false} = Egress.refresh_before_turn(state)
      assert next.broker == session
      assert next.brokered == %{}
      assert next.inference_credentials == creds

      for token <- [old, new_access] do
        refute inspect(next, limit: :infinity, printable_limit: :infinity) =~ token
      end

      refute function_exported?(Egress, :refresh_platform_chatgpt, 2)
      refute function_exported?(Egress, :refresh_platform_chatgpt, 3)
    end
  end
end
