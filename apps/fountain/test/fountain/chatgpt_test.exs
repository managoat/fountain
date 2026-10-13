defmodule Fountain.ChatGPTTest do
  @moduledoc """
  ChatGPT subscriptions (ADR 0070): linking, the refresh and its keepalive,
  resolution for codex, the pre-turn token read and the sandbox's auth.json.
  Every call to auth.openai.com is a `Req.Test` stub (`config/test.exs`).

  `async: false`: the broker switch is application env.
  """
  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.BrokerTestHelpers

  alias Fountain.{Audit, ChatGPT, InferenceCredentials, Repo}
  alias Fountain.ChatGPT.Subscription
  alias Fountain.Conversations.{CodexChatGPT, Egress}
  alias Fountain.InferenceCredentials.Source

  @auth_claim "https://api.openai.com/auth"

  setup do
    enable_broker()
    {:ok, user: insert_verified_user()}
  end

  describe "connect and disconnect" do
    test "a user's link stores encrypted tokens and the claims, and is audited", %{user: user} do
      assert {:ok, sub} =
               ChatGPT.connect({:user, user.id}, tokens(), method: "device_code", actor: "ui")

      assert sub.user_id == user.id
      assert sub.account_id == "acct_1"
      assert sub.plan_type == "plus"
      assert sub.status == "active"
      assert %DateTime{} = sub.expires_at

      assert [event] = chatgpt_events(user)
      assert event.action == "chatgpt_subscription.connected"
      assert event.actor == "ui"
      assert event.metadata == %{"method" => "device_code", "plan_type" => "plus"}
    end

    test "a relink replaces the tokens on the same row", %{user: user} do
      {:ok, first} = ChatGPT.connect({:user, user.id}, tokens())
      {:ok, second} = ChatGPT.connect({:user, user.id}, tokens(account_id: "acct_2"))

      assert second.id == first.id
      assert second.account_id == "acct_2"
      assert Repo.aggregate(Subscription, :count) == 1
    end

    test "each owner reaches only its own row", %{user: user} do
      other = insert_verified_user()
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())

      assert ChatGPT.get({:user, other.id}) == nil
      assert ChatGPT.get(:platform) == nil
      :ok = ChatGPT.disconnect({:user, other.id})
      assert ChatGPT.active?({:user, user.id})
    end

    test "the deployment's link is an admin event", %{user: admin} do
      {:ok, sub} =
        ChatGPT.connect(:platform, tokens(), method: "auth_json", actor_user_id: admin.id)

      assert sub.user_id == nil

      assert [event] = Audit._unsafe_list_recent_admin(5)
      assert event.event_type == "admin.platform_chatgpt.connected"
      assert event.actor_user_id == admin.id
    end

    test "a pasted auth.json must be a ChatGPT sign-in with a refresh token", %{user: user} do
      owner = {:user, user.id}
      assert {:ok, _} = ChatGPT.connect_auth_json(owner, auth_json())

      assert {:error, :not_a_chatgpt_login} =
               ChatGPT.connect_auth_json(owner, auth_json(auth_mode: "apikey"))

      assert {:error, :no_refresh_token} =
               ChatGPT.connect_auth_json(owner, auth_json(refresh_token: ""))

      assert {:error, :invalid_auth_json} = ChatGPT.connect_auth_json(owner, "{")

      assert {:error, :invalid_id_token} =
               ChatGPT.connect(owner, %{tokens() | id_token: "not-a-jwt"})
    end

    test "disconnect deletes the row and audits only a removal", %{user: user} do
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      :ok = ChatGPT.disconnect({:user, user.id}, actor: "ui")
      :ok = ChatGPT.disconnect({:user, user.id}, actor: "ui")

      assert ChatGPT.get({:user, user.id}) == nil

      assert ["chatgpt_subscription.connected", "chatgpt_subscription.disconnected"] ==
               user |> chatgpt_events() |> Enum.map(& &1.action) |> Enum.sort()
    end

    test "deleting the account deletes its subscription", %{user: user} do
      {:ok, sub} = ChatGPT.connect({:user, user.id}, tokens())
      Repo.delete!(user)
      refute Repo.get(Subscription, sub.id)
    end
  end

  describe "refresh/1" do
    test "rotates both tokens and stamps the row", %{user: user} do
      {:ok, sub} = ChatGPT.connect({:user, user.id}, tokens())
      sub = age(sub, days: 7)

      stub_auth(fn conn, body ->
        assert body["grant_type"] == "refresh_token"
        assert body["refresh_token"] == "rt_1"
        token_response(conn, access_token("at_2"), "rt_2")
      end)

      assert {:ok, fresh} = ChatGPT.refresh(sub)
      assert DateTime.compare(fresh.last_refreshed_at, sub.last_refreshed_at) == :gt
      assert {:ok, token} = ChatGPT.token_for({:user, user.id}, "acct_1")
      assert jti(token) == "at_2"

      # The rotated refresh token is the one the next refresh spends.
      stub_auth(fn conn, body ->
        assert body["refresh_token"] == "rt_2"
        token_response(conn, access_token("at_3"), "rt_3")
      end)

      assert {:ok, _} = ChatGPT.refresh(age(fresh, days: 7))
    end

    test "a terminal refusal revokes the subscription and is audited", %{user: user} do
      {:ok, sub} = ChatGPT.connect({:user, user.id}, tokens())

      stub_auth(fn conn, _body ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":{"code":"refresh_token_reused"}}))
      end)

      assert {:error, :revoked} = ChatGPT.refresh(sub)

      assert %{status: "revoked", revoked_reason: "refresh_token_reused"} =
               Repo.get(Subscription, sub.id)

      refute ChatGPT.active?({:user, user.id})

      assert "chatgpt_subscription.revoked" in Enum.map(chatgpt_events(user), & &1.action)
    end

    test "a transient failure keeps the row as it was", %{user: user} do
      {:ok, sub} = ChatGPT.connect({:user, user.id}, tokens())
      stub_auth(fn conn, _body -> Plug.Conn.send_resp(conn, 503, "upstream down") end)

      assert {:error, :refresh_failed} = ChatGPT.refresh(sub)
      assert Repo.get(Subscription, sub.id).access_token_ciphertext == sub.access_token_ciphertext
    end

    test "a row someone refreshed since it was read is not refreshed again", %{user: user} do
      {:ok, sub} = ChatGPT.connect({:user, user.id}, tokens())
      stale = %{sub | last_refreshed_at: DateTime.add(sub.last_refreshed_at, -60)}
      stub_auth(fn _conn, _body -> flunk("refreshed twice") end)

      assert {:ok, _} = ChatGPT.refresh(stale)
    end
  end

  describe "the keepalive" do
    test "refreshes only active subscriptions idle for more than six days", %{user: user} do
      other = insert_verified_user()
      {:ok, due} = ChatGPT.connect({:user, user.id}, tokens())
      {:ok, recent} = ChatGPT.connect({:user, other.id}, tokens(account_id: "acct_2"))
      age(due, days: 7)
      age(recent, days: 5)

      stub_auth(fn conn, _body -> token_response(conn, access_token("at_new"), "rt_new") end)

      assert :ok = perform_job(Fountain.Workers.ChatGPTKeepalive, %{})

      assert DateTime.diff(DateTime.utc_now(), Repo.get(Subscription, due.id).last_refreshed_at) <
               60

      assert DateTime.diff(
               DateTime.utc_now(),
               Repo.get(Subscription, recent.id).last_refreshed_at
             ) > 86_400
    end
  end

  describe "token_for/2, before a turn" do
    test "reads the stored token without calling OpenAI", %{user: user} do
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      stub_auth(fn _conn, _body -> flunk("a turn must not exchange tokens") end)

      assert {:ok, token} = ChatGPT.token_for({:user, user.id}, "acct_1")
      assert jti(token) == "at_1"
    end

    test "refreshes first when the stored token is about to expire", %{user: user} do
      {:ok, _} =
        ChatGPT.connect({:user, user.id}, tokens(access_token: access_token("at_1", 120)))

      stub_auth(fn conn, _body -> token_response(conn, access_token("at_2"), "rt_2") end)

      assert {:ok, token} = ChatGPT.token_for({:user, user.id}, "acct_1")
      assert jti(token) == "at_2"
    end

    test "a subscription that is gone or on another account needs reconnecting", %{user: user} do
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())

      assert {:error, :chatgpt_reconnect_required} =
               ChatGPT.token_for({:user, user.id}, "acct_other")

      ChatGPT.disconnect({:user, user.id})

      assert {:error, :chatgpt_reconnect_required} =
               ChatGPT.token_for({:user, user.id}, "acct_1")
    end
  end

  describe "resolution for codex" do
    test "the user's own subscription wins over the deployment's and any API key", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(:platform, tokens(account_id: "acct_platform"))
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())

      assert {:ok, source, creds} = resolve(user)
      assert %Source{scope: :grant, kind: :codex_chatgpt_access_token} = source
      assert source.identity == "chatgpt:" <> user.id
      assert source.revision == "acct_1"
      assert jti(creds.codex_chatgpt_access_token) == "at_1"
      refute Map.has_key?(creds, :openai_api_key)
    end

    test "without one of its own, the deployment's serves", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(:platform, tokens(account_id: "acct_platform"))

      assert {:ok, %Source{scope: :platform, identity: "platform:chatgpt"} = source, _} =
               resolve(user)

      assert source.revision == "acct_platform"
    end

    test "an explicit set, another runtime, or no broker skips subscriptions", %{user: user} do
      set = put_openai_key(user)
      {:ok, _} = ChatGPT.connect(:platform, tokens(account_id: "acct_platform"))

      assert {:ok, %Source{scope: :credential}, _} = resolve(user, credential_set_id: set.id)

      assert {:ok, %Source{scope: :credential}, _} =
               InferenceCredentials.resolve(user.id, "openai/gpt-5", "acp")

      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      disable_broker()
      assert {:ok, %Source{scope: :credential}, _} = resolve(user)
    end

    test "a conversation whose subscription is gone is told to reconnect", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      {:ok, source, _} = resolve(user)

      assert :ok = InferenceCredentials.validate_source(user.id, source)

      # A refresh keeps the source.
      stub_auth(fn conn, _body -> token_response(conn, access_token("at_2"), "rt_2") end)
      {:ok, _} = ChatGPT.refresh(age(ChatGPT.get({:user, user.id}), days: 7))
      assert :ok = InferenceCredentials.validate_source(user.id, source)

      ChatGPT.disconnect({:user, user.id})

      assert {:error, :chatgpt_reconnect_required} =
               InferenceCredentials.validate_source(user.id, source)

      # Linked again to the same account, it serves again; another account is
      # a different source.
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      assert :ok = InferenceCredentials.validate_source(user.id, source)

      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens(account_id: "acct_2"))

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, source)
    end

    test "a source the retired implementation wrote still renders but never validates", %{
      user: user
    } do
      stored = %{
        "scope" => "grant",
        "kind" => "codex_chatgpt_access_token",
        "identity" => "chatgpt_grant:" <> Ecto.UUID.generate(),
        "grant_id" => Ecto.UUID.generate(),
        "origin" => "own"
      }

      assert Source.summary(stored) == %{origin: "own", scope: "grant"}
      assert Source.chatgpt_owner(stored) == nil
      _ = user
    end
  end

  describe "the broker and the sandbox" do
    test "the token is brokered on chatgpt.com and the sandbox gets a placeholder" do
      {env_creds, brokered, implicit} =
        Fountain.Broker.split_inference(%{codex_chatgpt_access_token: "at_secret"})

      assert env_creds.codex_chatgpt_access_token == "__codex_chatgpt_access_token__"
      assert brokered == %{"CODEX_CHATGPT_ACCESS_TOKEN" => "at_secret"}

      assert [%{host: "chatgpt.com", auth_type: "substitute"}] =
               implicit["CODEX_CHATGPT_ACCESS_TOKEN"]

      assert CodexChatGPT.env(Managoat.Runtimes.Codex, env_creds) ==
               [{"CODEX_CHATGPT_ACCESS_TOKEN", "__codex_chatgpt_access_token__"}]

      assert CodexChatGPT.env(Managoat.Runtimes.Claude, env_creds) == []
      assert CodexChatGPT.peer_auth(Managoat.Runtimes.Codex, env_creds) == :none
      assert CodexChatGPT.peer_auth(Managoat.Runtimes.Codex, %{openai_api_key: "k"}) == :api_key
    end

    test "prepare_sandbox writes a chatgptAuthTokens auth.json with no secret in it", %{
      user: user
    } do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      {:ok, source, creds} = resolve(user)
      handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "s"}
      test_pid = self()

      stub(Managoat.Sandbox, :write_file, fn ^handle, path, body, opts ->
        send(test_pid, {:wrote, path, body, opts})
        :ok
      end)

      assert :ok = CodexChatGPT.prepare_sandbox(handle, "codex", source, user.id)
      assert_received {:wrote, path, body, [mode: 0o600]}
      assert path == Managoat.Runtimes.Codex.auth_path()

      auth = Jason.decode!(body)
      assert auth["auth_mode"] == "chatgptAuthTokens"
      assert auth["tokens"]["access_token"] == "__codex_chatgpt_access_token__"
      assert auth["tokens"]["account_id"] == "acct_1"
      assert auth["tokens"]["refresh_token"] == ""
      refute body =~ creds.codex_chatgpt_access_token
      refute body =~ "rt_1"
      refute body =~ "someone@example.com"

      {:ok, claims} = Fountain.ChatGPT.Tokens.decode_payload(auth["tokens"]["id_token"])
      assert claims[@auth_claim]["chatgpt_plan_type"] == "plus"

      # Another runtime or an API-key source is the library's; another user's
      # subscription is refused.
      assert :skip = CodexChatGPT.prepare_sandbox(handle, "claude", source, user.id)
      assert :skip = CodexChatGPT.prepare_sandbox(handle, "codex", Source.credential(), user.id)

      assert {:error, :chatgpt_reconnect_required} =
               CodexChatGPT.prepare_sandbox(handle, "codex", source, Ecto.UUID.generate())
    end

    test "the refresh before a turn puts the stored token into the broker's rule", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect({:user, user.id}, tokens())
      {:ok, source, creds} = resolve(user)
      {_env, brokered, bindings} = Fountain.Broker.split_inference(creds)

      state = %{
        conversation_id: Ecto.UUID.generate(),
        user_id: user.id,
        broker: %{
          vault: "c-test",
          token: "av_sess",
          expires_at: DateTime.add(DateTime.utc_now(), 3_600)
        },
        broker_network: :unrestricted,
        brokered: brokered,
        broker_bindings: bindings,
        tenant_keys: [],
        secret_sources: nil,
        tenant_key: nil,
        inference_model: "openai/gpt-5",
        inference_source: source,
        inference_credentials: creds,
        sprite_env: []
      }

      stub_auth(fn _conn, _body -> flunk("a turn must not exchange tokens") end)
      stub(Fountain.Broker, :refresh, fn _, _, _, _ -> flunk("nothing moved") end)
      stub(Fountain.Broker, :prepare, fn _, _, _, _ -> flunk("the session is not expiring") end)
      assert {_same, false} = Egress.refresh_before_turn(state)

      # The keepalive refreshed it; the next turn carries the new token.
      stub_auth(fn conn, _body -> token_response(conn, access_token("at_kept"), "rt_2") end)
      {:ok, _} = ChatGPT.refresh(age(ChatGPT.get({:user, user.id}), days: 7))
      test_pid = self()

      stub(Fountain.Broker, :refresh, fn _conv, brokered, _bindings, _opts ->
        send(test_pid, {:rules, brokered["CODEX_CHATGPT_ACCESS_TOKEN"]})
        {:ok, 1}
      end)

      stub_auth(fn _conn, _body -> flunk("a turn must not exchange tokens") end)
      assert {next, false} = Egress.refresh_before_turn(state)
      assert_received {:rules, sent}
      assert jti(sent) == "at_kept"
      assert jti(next.inference_credentials.codex_chatgpt_access_token) == "at_kept"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp chatgpt_events(user) do
    user.id
    |> Audit.list_recent_for_user()
    |> Enum.filter(&String.starts_with?(&1.action, "chatgpt_subscription."))
  end

  defp jwt(claims) do
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    header <> "." <> (claims |> Jason.encode!() |> Base.url_encode64(padding: false)) <> ".sig"
  end

  # A token is told apart by its `jti`; its `exp` is what `Tokens.expires_at/1` reads.
  defp access_token(jti, seconds \\ 10 * 86_400),
    do: jwt(%{"jti" => jti, "exp" => System.os_time(:second) + seconds})

  defp jti(token) do
    {:ok, claims} = Fountain.ChatGPT.Tokens.decode_payload(token)
    claims["jti"]
  end

  defp id_token(account_id) do
    jwt(%{
      "email" => "someone@example.com",
      @auth_claim => %{
        "chatgpt_account_id" => account_id,
        "chatgpt_user_id" => "user-x",
        "chatgpt_plan_type" => "plus"
      }
    })
  end

  defp tokens(opts \\ []) do
    %{
      access_token: Keyword.get(opts, :access_token, access_token("at_1")),
      refresh_token: "rt_1",
      id_token: id_token(Keyword.get(opts, :account_id, "acct_1"))
    }
  end

  defp auth_json(opts \\ []) do
    Jason.encode!(%{
      "auth_mode" => Keyword.get(opts, :auth_mode, "chatgpt"),
      "tokens" => %{
        "id_token" => id_token("acct_1"),
        "access_token" => access_token("at_1"),
        "refresh_token" => Keyword.get(opts, :refresh_token, "rt_1")
      }
    })
  end

  defp token_response(conn, access, refresh) do
    Req.Test.json(conn, %{
      "access_token" => access,
      "refresh_token" => refresh,
      "id_token" => id_token("acct_1")
    })
  end

  defp stub_auth(fun) do
    Req.Test.stub(Fountain.ChatGPT.OAuth, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      fun.(conn, Jason.decode!(raw))
    end)
  end

  defp age(sub, days: days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.truncate(:second)
    sub |> Ecto.Changeset.change(last_refreshed_at: at) |> Repo.update!()
  end

  defp put_openai_key(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-own")
    set
  end

  defp resolve(user, opts \\ []),
    do: InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", opts)
end
