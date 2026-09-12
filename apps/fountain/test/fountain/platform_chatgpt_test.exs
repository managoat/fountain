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
  alias Fountain.Conversations.Egress
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.PlatformChatGPT
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

  defp decrypt!(cipher) do
    {:ok, value} = Crypto.decrypt_platform(cipher)
    value
  end

  describe "connect_from_auth_json/2" do
    test "stores the grant, the claims and nothing secret on the trail" do
      admin = insert_verified_user()
      access = access_token(3_600)

      assert {:ok, %Account{} = account} =
               PlatformChatGPT.connect_from_auth_json(
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

      assert PlatformChatGPT.active?()
      assert PlatformChatGPT.access_token() == {:ok, access}
      assert %{status: "active", account_email: "admin@example.com"} = PlatformChatGPT.status()
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
               PlatformChatGPT.connect_from_auth_json(auth_json(%{auth_mode: "apiKey"}))

      assert {:error, :no_refresh_token} =
               PlatformChatGPT.connect_from_auth_json(auth_json(%{refresh_token: ""}))

      assert {:error, :invalid_auth_json} = PlatformChatGPT.connect_from_auth_json("not json")
      assert {:error, :invalid_auth_json} = PlatformChatGPT.connect_from_auth_json("{}")

      # No account id in the id_token: codex would have nothing to send.
      assert {:error, :invalid_id_token} =
               PlatformChatGPT.connect_from_auth_json(
                 auth_json(%{id_token: jwt(%{"email" => "x"})})
               )

      refute PlatformChatGPT.active?()
      assert events("admin.platform_chatgpt.connected") == []
    end
  end

  describe "access_token/0" do
    test "not connected, then served from the row without a refresh while fresh" do
      assert PlatformChatGPT.access_token() == {:error, :not_connected}
      assert PlatformChatGPT.credential() == :none

      access = access_token(3_600)
      connect!(%{access_token: access})
      assert PlatformChatGPT.access_token() == {:ok, access}
      assert PlatformChatGPT.credential() == {:ok, access}
    end

    test "credential(refresh: false) answers from the row and never dials out" do
      stale = access_token(60)
      connect!(%{access_token: stale})
      # No stub for /oauth/token: a refresh here would raise.
      assert PlatformChatGPT.credential(refresh: false) == {:ok, stale}

      assert {:ok, %Source{origin: :platform}, %{codex_chatgpt_access_token: ^stale}} =
               InferenceCredentials.select("openai/gpt-5.5-codex", %{}, "codex", refresh: false)

      stub_refusal()
      assert PlatformChatGPT.access_token() == {:error, :revoked}
      assert PlatformChatGPT.credential(refresh: false) == :none
    end

    test "refreshes within the margin, persists the rotated refresh token, then serves the new one" do
      connect!(%{access_token: access_token(60), refresh_token: "rt_original"})
      new_access = access_token(7_200, %{"n" => 2})
      stub_refresh(%{access_token: new_access, refresh_token: "rt_rotated"})

      assert PlatformChatGPT.access_token() == {:ok, new_access}

      account = row()
      assert decrypt!(account.refresh_token_ciphertext) == "rt_rotated"
      assert decrypt!(account.access_token_ciphertext) == new_access
      assert DateTime.diff(account.access_expires_at, DateTime.utc_now(), :second) > 7_000
      assert account.status == "active"

      # The second call is served from the row: a stub that only accepts the
      # original refresh token would answer `refresh_token_reused` otherwise.
      assert PlatformChatGPT.access_token() == {:ok, new_access}
      assert events("admin.platform_chatgpt.revoked") == []
    end

    test "a terminal refusal marks the grant revoked with the server's reason" do
      connect!(%{access_token: access_token(60)})
      stub_refusal("refresh_token_reused")

      assert PlatformChatGPT.access_token() == {:error, :revoked}
      assert %Account{status: "revoked", revoked_reason: "refresh_token_reused"} = row()
      assert PlatformChatGPT.credential() == :none
      refute PlatformChatGPT.active?()

      assert %{status: "revoked", revoked_reason: "refresh_token_reused"} =
               PlatformChatGPT.status()

      assert [event] = events("admin.platform_chatgpt.revoked")
      assert is_nil(event.actor_user_id)
      assert event.metadata["actor"] == "system:platform_chatgpt"
      assert event.metadata["reason"] == "refresh_token_reused"

      # Revoked stays revoked: no second round-trip, no second event.
      assert PlatformChatGPT.access_token() == {:error, :revoked}
      assert length(events("admin.platform_chatgpt.revoked")) == 1

      # The sandbox file's claims are still served: the file holds a
      # placeholder, and a revoke landing mid-provision must not fail the
      # spawn whose token the broker already took.
      assert {:ok, %{account_id: "acct_platform_1"}} = PlatformChatGPT.sandbox_auth()
    end

    test "a bare invalid_grant is terminal too" do
      connect!(%{access_token: access_token(60)})
      stub_auth(%{"/oauth/token" => fn _ -> {400, %{"error" => "invalid_grant"}} end})

      assert PlatformChatGPT.access_token() == {:error, :revoked}
      assert row().revoked_reason == "invalid_grant"
    end

    test "a transient failure keeps the row and the old token" do
      access = access_token(60)
      connect!(%{access_token: access, refresh_token: "rt_original"})
      stub_auth(%{"/oauth/token" => fn _ -> {503, %{"error" => "try_later"}} end})

      assert {:error, {:token, 503, "try_later"}} = PlatformChatGPT.access_token()

      account = row()
      assert account.status == "active"
      assert decrypt!(account.refresh_token_ciphertext) == "rt_original"
      assert decrypt!(account.access_token_ciphertext) == access
      assert events("admin.platform_chatgpt.revoked") == []
    end
  end

  describe "connect_workspace_token/3" do
    test "an opaque token with an admin-set expiry is served until it lapses, then expires" do
      admin = insert_verified_user()

      assert {:ok, account} =
               PlatformChatGPT.connect_workspace_token("wst_opaque_token", ~D[2030-01-01],
                 actor_user_id: admin.id,
                 account_id: "acct_ws"
               )

      assert account.kind == "workspace_token"
      assert is_nil(account.refresh_token_ciphertext)
      assert account.account_id == "acct_ws"
      assert account.access_expires_at == ~U[2030-01-01 23:59:59Z]
      assert PlatformChatGPT.access_token() == {:ok, "wst_opaque_token"}
      assert %{kind: "workspace_token", status: "active"} = PlatformChatGPT.status()

      assert [event] = events("admin.platform_chatgpt.connected")
      assert event.metadata["method"] == "workspace_token"
      refute inspect(event.metadata) =~ "wst_opaque"

      # Lapsed: the row goes expired with a system event, once.
      row()
      |> Ecto.Changeset.change(access_expires_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      assert PlatformChatGPT.access_token() == {:error, :expired}
      assert %Account{status: "expired"} = row()
      assert [expired] = events("admin.platform_chatgpt.expired")
      assert expired.metadata["actor"] == "system:platform_chatgpt"
      assert PlatformChatGPT.access_token() == {:error, :expired}
      assert length(events("admin.platform_chatgpt.expired")) == 1
      assert PlatformChatGPT.credential() == :none
    end

    test "a JWT-shaped token supplies its own account id and expiry" do
      token =
        access_token(3_600, %{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_jwt"}
        })

      assert {:ok, account} = PlatformChatGPT.connect_workspace_token(token, nil)
      assert account.account_id == "acct_jwt"
      assert DateTime.diff(account.access_expires_at, DateTime.utc_now(), :second) > 3_000
    end

    test "an opaque token needs an account id: codex sends it on every request" do
      assert {:error, :no_account_id} = PlatformChatGPT.connect_workspace_token("wst_opaque", nil)

      assert {:error, :no_account_id} =
               PlatformChatGPT.connect_workspace_token("wst_opaque", nil, account_id: "  ")

      refute PlatformChatGPT.active?()
      assert PlatformChatGPT.sandbox_auth() == :none

      assert {:ok, _} =
               PlatformChatGPT.connect_workspace_token("wst_opaque", nil, account_id: " acct_x ")

      assert {:ok, %{account_id: "acct_x"}} = PlatformChatGPT.sandbox_auth()
    end

    test "refuses a blank, a whitespace-bearing, or an oversized value" do
      assert {:error, :invalid_token} = PlatformChatGPT.connect_workspace_token("", nil)
      assert {:error, :invalid_token} = PlatformChatGPT.connect_workspace_token("a b", nil)

      assert {:error, :invalid_token} =
               PlatformChatGPT.connect_workspace_token(String.duplicate("x", 9_000), nil)

      refute PlatformChatGPT.active?()
    end
  end

  describe "disconnect/1" do
    test "removes the row and records once" do
      admin = insert_verified_user()
      connect!()

      assert :ok = PlatformChatGPT.disconnect(actor_user_id: admin.id)
      assert PlatformChatGPT.status() == :not_connected
      assert Repo.all(Account) == []

      assert :ok = PlatformChatGPT.disconnect(actor_user_id: admin.id)
      assert [event] = events("admin.platform_chatgpt.disconnected")
      assert event.actor_user_id == admin.id
      assert event.metadata["account_id"] == "acct_platform_1"
    end
  end

  describe "sandbox_auth/0" do
    test "is the real account id and an unsigned id_token with the three claims and no email" do
      assert PlatformChatGPT.sandbox_auth() == :none
      connect!()

      assert {:ok, %{account_id: "acct_platform_1", id_token: id_token}} =
               PlatformChatGPT.sandbox_auth()

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

  describe "keepalive/0" do
    test "skips when not connected, recently renewed, or a workspace token" do
      assert PlatformChatGPT.keepalive() == {:ok, :skipped}

      connect!()
      assert PlatformChatGPT.keepalive() == {:ok, :skipped}

      {:ok, _} = PlatformChatGPT.connect_workspace_token("wst_static", nil, account_id: "acct_ws")

      row()
      |> Ecto.Changeset.change(last_refreshed_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      assert PlatformChatGPT.keepalive() == {:ok, :skipped}
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

      assert PlatformChatGPT.keepalive() == {:ok, :refreshed}
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

      assert PlatformChatGPT.keepalive() == {:error, :revoked}
      assert row().revoked_reason == "refresh_token_invalidated"
      assert :ok = perform_job(Fountain.Workers.PlatformChatGPTKeepalive, %{})
    end
  end

  describe "InferenceCredentials.select/3 (ADR 0047 decision 6)" do
    test "a codex agent with no tenant key takes the grant, at :platform" do
      access = access_token()
      connect!(%{access_token: access})

      assert InferenceCredentials.select("openai/gpt-5.5-codex", %{}, "codex") ==
               {:ok, Source.platform(), %{codex_chatgpt_access_token: access}}

      # The tenant's other credentials survive the merge.
      assert {:ok, %Source{origin: :platform},
              %{anthropic_api_key: "sk-ant", codex_chatgpt_access_token: ^access}} =
               InferenceCredentials.select(
                 "openai/gpt-5.5-codex",
                 %{anthropic_api_key: "sk-ant"},
                 "codex"
               )
    end

    test "an unbrokered conversation never takes the grant: the token would land in the sandbox" do
      connect!()

      assert InferenceCredentials.select("openai/gpt-5.5-codex", %{}, "codex", brokered: false) ==
               {:error, :no_credential}

      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      assert InferenceCredentials.select("openai/gpt-5.5-codex", %{}, "codex", brokered: false) ==
               {:ok, Source.platform(), %{openai_api_key: "sk-platform"}}
    end

    test "the tenant's own OpenAI key always wins" do
      connect!()
      own = %{openai_api_key: "sk-mine"}

      assert {:ok, %Source{origin: :own, scope: :credential}, ^own} =
               InferenceCredentials.select("openai/gpt-5.5-codex", own, "codex")
    end

    test "opencode on an openai model never takes the grant" do
      connect!()

      assert InferenceCredentials.select("openai/gpt-5.5", %{}, "opencode") ==
               {:error, :no_credential}

      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      assert InferenceCredentials.select("openai/gpt-5.5", %{}, "opencode") ==
               {:ok, Source.platform(), %{openai_api_key: "sk-platform"}}

      assert InferenceCredentials.select("openai/gpt-5.5", %{}) ==
               {:ok, Source.platform(), %{openai_api_key: "sk-platform"}}
    end

    test "a revoked grant falls through to the platform key, and to nothing" do
      connect!(%{access_token: access_token(60)})
      stub_refusal()
      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      assert InferenceCredentials.select("openai/gpt-5.5-codex", %{}, "codex") ==
               {:ok, Source.platform(), %{openai_api_key: "sk-platform"}}

      Application.delete_env(:fountain, :platform_openai_api_key)

      assert InferenceCredentials.select("openai/gpt-5.5-codex", %{}, "codex") ==
               {:error, :no_credential}
    end

    test "the ceiling gate counts the grant as platform-served" do
      user = insert_verified_user()
      refute PlatformInference.serves?("openai", "codex", true)
      assert :ok = PlatformInference.gate(user.id, "openai/gpt-5.5-codex", "codex")

      connect!()
      assert PlatformInference.serves?("openai", "codex", true)
      # The same question select/4 asks: unbrokered, the grant is never
      # handed out, so the gate must not refuse for it either.
      refute PlatformInference.serves?("openai", "codex", false)
      refute PlatformInference.serves?("openai", "opencode", true)
      refute PlatformInference.serves?("anthropic", "codex", true)
      # With credits off the ceiling never trips, so the gate is :ok — the
      # point is that the branch runs, which `serves?/2` pins.
      assert :ok = PlatformInference.gate(user.id, "openai/gpt-5.5-codex", "codex")
    end
  end

  describe "titles for a conversation on the grant" do
    test "fall back to the platform OpenAI key, and to no title without one" do
      creds = %{codex_chatgpt_access_token: "at_placeholder"}

      assert {:error, :no_credentials} =
               Fountain.Conversations.TitleGenerator.generate("fix the login bug", creds)

      Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")

      Req
      |> expect(:post, fn url, opts ->
        assert url =~ "api.openai.com"
        assert Enum.any?(Keyword.get(opts, :headers, []), fn {_k, v} -> v =~ "sk-platform" end)
        refute inspect(opts) =~ "at_placeholder"
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "Fix Login"}}]}}}
      end)

      assert {:ok, "Fix Login"} =
               Fountain.Conversations.TitleGenerator.generate("fix the login bug", creds)
    end
  end

  describe "the broker and the per-turn re-read (decisions 4 and 5)" do
    test "split_inference/2 brokers the grant to chatgpt.com with an unprefixed placeholder" do
      {creds, brokered, implicit} =
        Broker.split_inference(%{codex_chatgpt_access_token: "at_real"})

      assert creds == %{codex_chatgpt_access_token: "__codex_chatgpt_access_token__"}
      assert brokered == %{"CODEX_CHATGPT_ACCESS_TOKEN" => "at_real"}

      assert [%{host: "chatgpt.com"}] = implicit["CODEX_CHATGPT_ACCESS_TOKEN"]
      assert Managoat.Broker.Injector.valid_placeholder?("__codex_chatgpt_access_token__")
      assert Broker.inference_keys()["CODEX_CHATGPT_ACCESS_TOKEN"] == :codex_chatgpt_access_token
    end

    test "refresh_platform_chatgpt/2 swaps a rotated token into both copies and says so" do
      old = access_token(60)
      connect!(%{access_token: old})
      new_access = access_token(7_200, %{"n" => 2})
      stub_refresh(%{access_token: new_access})

      creds = %{codex_chatgpt_access_token: old, anthropic_api_key: "sk-ant"}
      brokered = %{"CODEX_CHATGPT_ACCESS_TOKEN" => old, "ANTHROPIC_API_KEY" => "sk-ant"}

      assert {creds, brokered, true} = Egress.refresh_platform_chatgpt(creds, brokered)
      assert creds.codex_chatgpt_access_token == new_access
      assert brokered["CODEX_CHATGPT_ACCESS_TOKEN"] == new_access
      assert brokered["ANTHROPIC_API_KEY"] == "sk-ant"

      # Unchanged the second time: the row is fresh now.
      assert {^creds, ^brokered, false} = Egress.refresh_platform_chatgpt(creds, brokered)
    end

    test "refresh_platform_chatgpt/2 leaves a conversation not on the grant, or on a tenant's own value, alone" do
      connect!(%{access_token: access_token(60)})
      stub_refresh()

      assert {%{}, %{}, false} = Egress.refresh_platform_chatgpt(%{}, %{})

      creds = %{codex_chatgpt_access_token: "at_old"}
      brokered = %{"CODEX_CHATGPT_ACCESS_TOKEN" => "tenant-owns-this-name"}
      assert {^creds, ^brokered, false} = Egress.refresh_platform_chatgpt(creds, brokered)
    end

    test "refresh_platform_chatgpt/2 keeps the old token when the grant is gone" do
      old = access_token(60)
      connect!(%{access_token: old})
      stub_refusal()

      creds = %{codex_chatgpt_access_token: old}
      brokered = %{"CODEX_CHATGPT_ACCESS_TOKEN" => old}
      assert {^creds, ^brokered, false} = Egress.refresh_platform_chatgpt(creds, brokered)
    end
  end
end
