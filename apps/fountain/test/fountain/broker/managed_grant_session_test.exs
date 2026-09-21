defmodule Fountain.Broker.Native.ManagedGrantSessionTest do
  # ADR 0052 decisions 5 and 6, built by ADR 0060 stage 3: a broker session
  # carries which managed ChatGPT grant it may use as authorization data, its
  # issuance is fenced on the grant row, and every request is authorized
  # against the durable generation. Every case runs for both owners a grant
  # can have. The platform row is one per deployment, so async: false.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.Broker
  alias Fountain.Broker.Native.{Session, Sessions}
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.PlatformChatGPT.Account
  alias Managoat.Broker.{ProtectedCredential, ProtectedRule, Rule}

  @keys [:broker_listen_port, :broker_proxy_url]
  @protected %{
    protected: true,
    scheme: :https,
    host: "chatgpt.com",
    port: 443,
    method: "POST",
    target: "/backend-api/codex/responses"
  }
  @ordinary %{scheme: :https, host: "api.github.com", port: 443, method: "GET", target: "/user"}

  setup do
    previous = for key <- @keys, do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 0)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    {:ok, user: user, conv: conv}
  end

  # A grant of the owner under test, its bearer, and the ref a conversation
  # pinned to it would carry.
  defp grant(:platform, _user) do
    access = access_token(3_600, %{"owner" => "platform"})
    account = connect!(%{access_token: access})
    {account, access, ref(account)}
  end

  defp grant(:user, user) do
    access = access_token(3_600, %{"owner" => "user"})
    account = user_grant!(user.id, %{access_token: access})
    {account, access, ref(account)}
  end

  defp ref(%Account{user_id: nil} = a),
    do: %{owner: :platform, grant_id: a.id, generation: a.generation}

  defp ref(%Account{user_id: user_id} = a),
    do: %{owner: {:user, user_id}, grant_id: a.id, generation: a.generation}

  defp prepare(conv, user, managed, brokered \\ %{"GITHUB_TOKEN" => "ghp_ordinary"}),
    do: Broker.prepare(conv.id, brokered, %{}, user_id: user.id, managed: managed)

  defp row(conv), do: Repo.one!(from s in Session, where: s.conversation_id == ^conv.id)

  defp end_generation(%Account{user_id: nil}), do: ChatGPTAccounts.platform_disconnect()

  defp end_generation(%Account{id: id, user_id: user_id}),
    do: ChatGPTAccounts.disconnect_for_user(id, user_id)

  for owner <- [:platform, :user] do
    describe "#{owner} grant: issuance" do
      @describetag owner: owner

      test "the session stores the pin and the account from the row, and no bearer anywhere",
           %{owner: owner, user: user, conv: conv} do
        {account, access, managed} = grant(owner, user)
        assert {:ok, session} = prepare(conv, user, managed)

        stored = row(conv)
        assert stored.managed_grant_id == account.id
        assert stored.managed_grant_generation == account.generation
        assert stored.managed_grant_owner_id == account.user_id
        assert stored.managed_identity == account.account_id
        assert is_nil(stored.managed_revoked_at)

        {:ok, dek} = Crypto.load_tenant_key(user.id)
        {:ok, rules} = Crypto.decrypt(stored.rules_ciphertext, dek, "fountain.broker.rules")
        refute rules =~ access
        refute rules =~ "codex_chatgpt_access_token"
        refute inspect(stored, limit: :infinity) =~ access

        assert stored.meta["credential_keys"]["codex-chatgpt"] == ["CODEX_CHATGPT_ACCESS_TOKEN"]

        assert {:ok, %Managoat.Broker.Session{} = looked_up} = Sessions.lookup(session.token)
        assert looked_up.authorization == {:managed, stored.id}
        assert looked_up.http_only

        assert %ProtectedRule{identity: identity, host: "chatgpt.com", port: 443} =
                 looked_up.protected

        assert identity == account.account_id
        assert ProtectedRule.valid_session?(looked_up)
        refute inspect(looked_up, limit: :infinity) =~ access
        refute :erlang.term_to_binary(looked_up) =~ access
      end

      test "an ordinary session is lookup-only, as before", %{user: user, conv: conv} do
        assert {:ok, session} =
                 Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

        assert {:ok, looked_up} = Sessions.lookup(session.token)
        assert is_nil(looked_up.authorization)
        refute looked_up.http_only
        assert is_nil(looked_up.protected)
        assert {:error, :denied} = Sessions.authorize({:managed, row(conv).id}, @protected)
      end

      # 0052's first adversarial case: selection happened, then the grant's
      # generation ended, then issuance resumes.
      test "a grant disconnected after it was selected mints no session",
           %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        :ok = end_generation(account)

        assert {:error, {:broker, :session, :managed_grant_inactive}} =
                 prepare(conv, user, managed)

        assert Repo.aggregate(Session, :count) == 0
      end

      test "a stale generation, a wrong owner and a malformed pin mint no session",
           %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        other = insert_verified_user()
        stranger = user_grant!(other.id)

        for bad <- [
              %{managed | generation: Ecto.UUID.generate()},
              %{managed | grant_id: Ecto.UUID.generate()},
              %{managed | grant_id: "not-a-uuid"},
              # Another tenant's grant, claimed as one's own and as theirs.
              %{owner: {:user, user.id}, grant_id: stranger.id, generation: stranger.generation},
              %{owner: {:user, other.id}, grant_id: stranger.id, generation: stranger.generation},
              # A grant under the other owner's scope.
              %{owner: :platform, grant_id: stranger.id, generation: stranger.generation},
              %{owner: {:user, user.id}, grant_id: account.id, generation: Ecto.UUID.generate()}
            ] do
          assert {:error, {:broker, :session, :managed_grant_inactive}} = prepare(conv, user, bad)
        end

        assert Repo.aggregate(Session, :count) == 0
      end

      test "an input that names the managed credential or its destination fails closed",
           %{owner: owner, user: user, conv: conv} do
        {_account, _access, managed} = grant(owner, user)

        assert {:error, {:broker, :session, :managed_credential_conflict}} =
                 prepare(conv, user, managed, %{"CODEX_CHATGPT_ACCESS_TOKEN" => "anything"})

        binding = %Fountain.SecretBindings.Binding{
          key: "OTHER",
          host: "*.com",
          auth_type: "bearer",
          headers: %{},
          enabled: true
        }

        assert {:error, {:broker, :session, :managed_destination_conflict}} =
                 Broker.prepare(conv.id, %{"OTHER" => "v"}, %{"OTHER" => [binding]},
                   user_id: user.id,
                   managed: managed
                 )

        assert Repo.aggregate(Session, :count) == 0
      end
    end

    describe "#{owner} grant: every request" do
      @describetag owner: owner

      test "a protected request gets the row's bearer and account; any other gets the rules",
           %{owner: owner, user: user, conv: conv} do
        {account, access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        reference = {:managed, row(conv).id}

        assert {:ok, %ProtectedCredential{} = credential} =
                 Sessions.authorize(reference, @protected)

        assert credential.bearer == access
        assert credential.identity == account.account_id
        refute inspect(credential) =~ access

        assert {:ok, rules} = Sessions.authorize(reference, @ordinary)
        assert Enum.all?(rules, &is_struct(&1, Rule))
        assert Enum.any?(rules, &(&1.credential == "ghp_ordinary"))
        refute inspect(rules, limit: :infinity) =~ access
      end

      # 0052's third case, its "missed invalidation" half: nothing marks the
      # session, and the durable generation alone denies.
      test "an ended generation denies even when the session was never marked",
           %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        reference = {:managed, row(conv).id}
        assert {:ok, %ProtectedCredential{}} = Sessions.authorize(reference, @protected)

        :ok = end_generation(account)
        Repo.update_all(Session, set: [managed_revoked_at: nil])

        assert {:error, :denied} = Sessions.authorize(reference, @protected)
        # Only the Codex backend closes; the conversation's other egress stays.
        assert {:ok, [_ | _]} = Sessions.authorize(reference, @ordinary)
      end

      test "a revoked or no longer active grant denies", %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        reference = {:managed, row(conv).id}

        Repo.update_all(from(a in Account, where: a.id == ^account.id), set: [status: "revoked"])
        assert {:error, :denied} = Sessions.authorize(reference, @protected)
      end

      test "a grant that now answers as another account denies: no bearer under an old id",
           %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)

        Repo.update_all(from(a in Account, where: a.id == ^account.id),
          set: [account_id: "acct-somebody-else"]
        )

        assert {:error, :denied} = Sessions.authorize({:managed, row(conv).id}, @protected)
      end

      test "revoke_grant/2 closes the Codex backend and keeps the rest",
           %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        reference = {:managed, row(conv).id}

        assert Broker.revoke_grant(account.id, Ecto.UUID.generate()) == 0
        assert {:ok, %ProtectedCredential{}} = Sessions.authorize(reference, @protected)

        assert Broker.revoke_grant(account.id, account.generation) == 1
        assert %DateTime{} = row(conv).managed_revoked_at
        assert {:error, :denied} = Sessions.authorize(reference, @protected)
        assert {:ok, [_ | _]} = Sessions.authorize(reference, @ordinary)

        # Idempotent, and `:all` finds nothing left to mark.
        assert Broker.revoke_grant(account.id, :all) == 0
      end

      test "an expired, a released and an unknown session deny",
           %{owner: owner, user: user, conv: conv} do
        {_account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        id = row(conv).id

        Repo.update_all(Session, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])
        assert {:error, :denied} = Sessions.authorize({:managed, id}, @protected)
        assert {:error, :denied} = Sessions.authorize({:managed, id}, @ordinary)

        :ok = Broker.release(conv.id)
        assert {:error, :denied} = Sessions.authorize({:managed, id}, @protected)

        assert {:error, :denied} =
                 Sessions.authorize({:managed, Ecto.UUID.generate()}, @protected)

        assert {:error, :denied} = Sessions.authorize(:not_a_reference, @protected)
        assert {:error, :denied} = Sessions.authorize(nil, @ordinary)
      end

      # 0052's second case, in sequence (the concurrent form is
      # `managed_grant_fence_test.exs`): a rule rewrite that lands after the
      # generation ended restores nothing and moves the session nowhere.
      test "a rule rewrite never writes the authorization columns",
           %{owner: owner, user: user, conv: conv} do
        {account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        before = row(conv)
        :ok = end_generation(account)
        Repo.update_all(Session, set: [managed_revoked_at: nil])

        assert {:ok, 1} =
                 Broker.refresh(conv.id, %{"GITHUB_TOKEN" => "ghp_edited"}, %{},
                   user_id: user.id,
                   managed: %{managed | generation: Ecto.UUID.generate()}
                 )

        rewritten = row(conv)

        for field <- ~w(managed_grant_id managed_grant_generation managed_grant_owner_id
                        managed_identity managed_revoked_at)a do
          assert Map.fetch!(rewritten, field) == Map.fetch!(before, field)
        end

        assert {:error, :denied} = Sessions.authorize({:managed, rewritten.id}, @protected)
        assert {:ok, rules} = Sessions.authorize({:managed, rewritten.id}, @ordinary)
        assert Enum.any?(rules, &(&1.credential == "ghp_edited"))
      end

      test "a store that cannot answer is unavailable, never a cached success",
           %{owner: owner, user: user, conv: conv} do
        {_account, _access, managed} = grant(owner, user)
        {:ok, _} = prepare(conv, user, managed)
        id = row(conv).id
        assert {:ok, %ProtectedCredential{}} = Sessions.authorize({:managed, id}, @protected)

        # A process with no database connection of its own, which is what an
        # exhausted pool or a dead node looks like from here: the read raises.
        # `spawn`, not a Task, so no `$callers` chain lends it the test's.
        test = self()
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

        try do
          for request <- [@protected, @ordinary] do
            spawn(fn -> send(test, {:answer, Sessions.authorize({:managed, id}, request)}) end)
            assert_receive {:answer, {:error, :unavailable}}, 5_000
          end
        after
          Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, test})
        end
      end
    end
  end

  # The invalidation half of ADR 0052 decision 5: every write that ends what a
  # session was issued for marks it, in that write's own transaction. Each
  # case leaves a second, unrelated managed session alone.
  describe "the grant's own transaction revokes its sessions" do
    setup %{user: user} do
      bystander = user_grant!(user.id)
      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, _} = prepare(other, user, ref(bystander))
      {:ok, bystander: other}
    end

    defp revoked?(conv), do: match?(%DateTime{}, row(conv).managed_revoked_at)

    test "a user's disconnect, and the removal after it", %{user: user, conv: conv} = ctx do
      {account, _access, managed} = grant(:user, user)
      {:ok, _} = prepare(conv, user, managed)

      :ok = ChatGPTAccounts.disconnect_for_user(account.id, user.id)
      assert revoked?(conv)
      refute revoked?(ctx.bystander)

      Repo.update_all(from(s in Session, where: s.conversation_id == ^conv.id),
        set: [managed_revoked_at: nil]
      )

      :ok = ChatGPTAccounts.remove_for_user(account.id, user.id)
      assert revoked?(conv)
      refute revoked?(ctx.bystander)
    end

    test "a user's reconnect ends every session of the old sign-in",
         %{user: user, conv: conv} = ctx do
      {account, _access, managed} = grant(:user, user)
      {:ok, _} = prepare(conv, user, managed)

      {:ok, view} =
        ChatGPTAccounts.reconnect_for_user(account.id, user.id, %{
          access_token: access_token(),
          refresh_token: "rt_again",
          id_token: id_token(%{account_id: account.account_id})
        })

      refute view.generation == account.generation
      assert revoked?(conv)
      refute revoked?(ctx.bystander)
      assert {:error, :denied} = Sessions.authorize({:managed, row(conv).id}, @protected)
    end

    test "a user's grant the auth server refuses", %{user: user, conv: conv} = ctx do
      stale = access_token(60)
      account = user_grant!(user.id, %{access_token: stale})
      {:ok, _} = prepare(conv, user, ref(account))
      stub_refusal("invalid_grant")

      assert {:error, :revoked} =
               ChatGPTAccounts.refresh_for_user(account.id, user.id, account.generation)

      assert revoked?(conv)
      refute revoked?(ctx.bystander)
    end

    test "a token rotation ends nothing", %{user: user, conv: conv} do
      account = user_grant!(user.id, %{access_token: access_token(60)})
      {:ok, _} = prepare(conv, user, ref(account))
      renewed = access_token(7_200, %{"renewed" => true})

      stub_refresh(%{
        expect_refresh: "rt_user",
        access_token: renewed,
        id_token: id_token(%{account_id: account.account_id})
      })

      assert :ok = ChatGPTAccounts.refresh_for_user(account.id, user.id, account.generation)
      refute revoked?(conv)

      assert {:ok, %ProtectedCredential{bearer: ^renewed}} =
               Sessions.authorize({:managed, row(conv).id}, @protected)
    end

    test "the platform's disconnect and its reconnect", %{user: user, conv: conv} = ctx do
      {_account, _access, managed} = grant(:platform, user)
      {:ok, _} = prepare(conv, user, managed)
      :ok = ChatGPTAccounts.platform_disconnect()
      assert revoked?(conv)
      refute revoked?(ctx.bystander)

      again = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      first = connect!()
      {:ok, _} = prepare(again, user, ref(first))
      second = connect!(%{refresh_token: "rt_again"})
      refute second.generation == first.generation
      assert revoked?(again)
      refute revoked?(ctx.bystander)
    end

    test "the platform's grant refused by the auth server, and a lapsed workspace token",
         %{user: user, conv: conv} = ctx do
      stale = connect!(%{access_token: access_token(60)})
      {:ok, _} = prepare(conv, user, ref(stale))
      stub_refusal()
      assert ChatGPTAccounts.platform_access_token() == {:error, :revoked}
      assert revoked?(conv)

      {:ok, workspace} =
        ChatGPTAccounts.platform_connect_workspace_token("wst_opaque_token", nil,
          account_id: "acct_ws"
        )

      lapsing = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, _} = prepare(lapsing, user, ref(workspace))

      Repo.update_all(from(a in Account, where: a.id == ^workspace.id),
        set: [access_expires_at: ~U[2020-01-01 00:00:00Z]]
      )

      assert ChatGPTAccounts.platform_access_token() == {:error, :expired}
      assert revoked?(lapsing)
      refute revoked?(ctx.bystander)
    end
  end

  describe "a user grant's owner" do
    test "an owner who may no longer use a grant is denied at issuance and at every request",
         %{user: user, conv: conv} do
      {account, _access, managed} = grant(:user, user)
      {:ok, _} = prepare(conv, user, managed)
      reference = {:managed, row(conv).id}
      assert {:ok, %ProtectedCredential{}} = Sessions.authorize(reference, @protected)

      user |> change(suspended_at: DateTime.utc_now(:second)) |> Repo.update!()

      assert {:error, :denied} = Sessions.authorize(reference, @protected)

      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

      assert {:error, {:broker, :session, :managed_grant_inactive}} =
               prepare(other, user, ref(account))
    end

    test "a user's grant cannot ride another tenant's session, even by a forged row",
         %{user: user} do
      {account, _access, managed} = grant(:user, user)
      other = insert_verified_user()
      theirs = insert_conversation(user_id: other.id, agent: insert_agent(user_id: other.id))

      assert {:error, {:broker, :session, :managed_grant_inactive}} =
               Broker.prepare(theirs.id, %{}, %{}, user_id: other.id, managed: managed)

      {:ok, _} = Broker.prepare(theirs.id, %{}, %{}, user_id: other.id)

      assert_raise Postgrex.Error, ~r/managed_grant_owner_is_session_owner/, fn ->
        Repo.update_all(from(s in Session, where: s.conversation_id == ^theirs.id),
          set: [
            managed_grant_id: account.id,
            managed_grant_generation: account.generation,
            managed_grant_owner_id: user.id,
            managed_identity: account.account_id
          ]
        )
      end
    end
  end

  describe "two grants of one user" do
    test "each session resolves its own bearer and account, and ending one leaves the other",
         %{user: user, conv: conv} do
      {personal, personal_access, personal_ref} = grant(:user, user)
      work_access = access_token(3_600, %{"owner" => "work"})
      work = user_grant!(user.id, %{access_token: work_access})
      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

      {:ok, _} = prepare(conv, user, personal_ref)
      {:ok, _} = prepare(other, user, ref(work))

      assert {:ok, %ProtectedCredential{bearer: ^personal_access, identity: personal_identity}} =
               Sessions.authorize({:managed, row(conv).id}, @protected)

      assert {:ok, %ProtectedCredential{bearer: ^work_access, identity: work_identity}} =
               Sessions.authorize({:managed, row(other).id}, @protected)

      assert personal_identity == personal.account_id
      assert work_identity == work.account_id
      refute personal_identity == work_identity

      :ok = ChatGPTAccounts.disconnect_for_user(personal.id, user.id)

      assert {:error, :denied} = Sessions.authorize({:managed, row(conv).id}, @protected)

      assert {:ok, %ProtectedCredential{bearer: ^work_access}} =
               Sessions.authorize({:managed, row(other).id}, @protected)

      assert Repo.get!(Account, work.id) == work
    end
  end
end
