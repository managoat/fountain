defmodule Fountain.InferenceCredentialSetGrantTest do
  # ADR 0060 decision 2: a credential set names one of its owner's ChatGPT
  # grants. A reference, held to the same owner by the changeset and by the
  # database. `async: false`: one test connects the platform row, which holds
  # 'inference:platform' exclusive for the whole test.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.Audit
  alias Fountain.ChatGPTAccounts
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Credential
  alias Fountain.PlatformChatGPT.Account

  @action "inference_credential_set.chatgpt_grant_changed"

  setup do
    user = insert_verified_user()
    other = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.create_set(user.id, "Work")
    %{user: user, other: other, dek: dek, set: set}
  end

  defp events(user) do
    user.id |> Audit.list_recent_for_user() |> Enum.filter(&(&1.action == @action))
  end

  defp stored(set), do: Repo.get!(Credential, set.id)

  describe "set_grant/3" do
    test "names a grant of the same owner, and records which, never a token", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Work plan", refresh_token: "rt_secret_value"})

      assert {:ok, %Credential{} = updated} =
               InferenceCredentials.set_grant(ctx.set, grant.id,
                 actor: "api_key:grant-test",
                 request_ip: "192.0.2.7"
               )

      assert updated.chatgpt_grant_id == grant.id
      assert stored(ctx.set).chatgpt_grant_id == grant.id
      # A repoint is not a credential change to the set's own keys.
      assert updated.revision == ctx.set.revision

      assert [event] = events(ctx.user)
      assert event.resource_type == "inference_credential_set"
      assert event.resource_id == ctx.set.id
      assert event.actor == "api_key:grant-test"
      assert event.request_ip == "192.0.2.7"

      assert event.metadata == %{
               "name" => "Work",
               "was" => nil,
               "now" => grant.id,
               "grant" => "Work plan"
             }

      refute inspect(event) =~ "rt_secret_value"
    end

    test "several sets may name one grant, and a set moves from one grant to another", ctx do
      first = user_grant!(ctx.user.id, %{name: "First"})
      second = user_grant!(ctx.user.id, %{name: "Second"})
      {:ok, personal} = InferenceCredentials.create_set(ctx.user.id, "Personal")

      assert {:ok, _} = InferenceCredentials.set_grant(ctx.set, first.id)
      assert {:ok, _} = InferenceCredentials.set_grant(personal, first.id)
      assert {:ok, moved} = InferenceCredentials.set_grant(ctx.set, second.id)

      assert moved.chatgpt_grant_id == second.id
      assert stored(personal).chatgpt_grant_id == first.id

      assert [%{metadata: %{"was" => was, "now" => now, "grant" => "Second"}} | _] =
               events(ctx.user)

      assert {was, now} == {first.id, second.id}
    end

    test "nil stops naming one, and says what was named", ctx do
      grant = user_grant!(ctx.user.id)
      {:ok, named} = InferenceCredentials.set_grant(ctx.set, grant.id)

      assert {:ok, cleared} = InferenceCredentials.set_grant(named, nil)
      assert is_nil(cleared.chatgpt_grant_id)
      assert is_nil(stored(ctx.set).chatgpt_grant_id)

      assert [%{metadata: %{"was" => was, "now" => nil, "grant" => nil}}, _named] =
               events(ctx.user)

      assert was == grant.id
    end

    test "naming what is already named writes and records nothing", ctx do
      grant = user_grant!(ctx.user.id)

      assert {:ok, unchanged} = InferenceCredentials.set_grant(ctx.set, nil)
      assert is_nil(unchanged.chatgpt_grant_id)
      assert events(ctx.user) == []

      {:ok, named} = InferenceCredentials.set_grant(ctx.set, grant.id)
      before = stored(ctx.set)

      # Another spelling of the id is the same grant.
      assert {:ok, ^before} = InferenceCredentials.set_grant(named, String.upcase(grant.id))
      assert stored(ctx.set) == before
      assert [_only] = events(ctx.user)
    end

    test "another account's grant, the platform's, a missing one and a malformed id are one refusal",
         ctx do
      foreign = user_grant!(ctx.other.id, %{name: "Theirs"})
      platform = connect!()

      for id <- [foreign.id, platform.id, Ecto.UUID.generate(), "not-a-uuid", ""] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 InferenceCredentials.set_grant(ctx.set, id)

        assert errors_on(changeset) == %{chatgpt_grant_id: [Credential.grant_message()]}
        # Nothing about the refused grant travels back.
        refute inspect(changeset.errors) =~ "Theirs"
      end

      assert is_nil(stored(ctx.set).chatgpt_grant_id)
      assert events(ctx.user) == []
      assert events(ctx.other) == []
    end

    test "a disconnected grant is refused by name; a revoked one may be named", ctx do
      gone = user_grant!(ctx.user.id, %{name: "Gone"})
      :ok = ChatGPTAccounts.disconnect_for_user(gone.id, ctx.user.id)

      assert {:error, %Ecto.Changeset{} = changeset} =
               InferenceCredentials.set_grant(ctx.set, gone.id)

      assert %{chatgpt_grant_id: [message]} = errors_on(changeset)
      assert message =~ "disconnected"
      assert is_nil(stored(ctx.set).chatgpt_grant_id)

      revoked = user_grant!(ctx.user.id, %{name: "Revoked"})
      Repo.update_all(from(a in Account, where: a.id == ^revoked.id), set: [status: "revoked"])

      assert {:ok, %{chatgpt_grant_id: id}} = InferenceCredentials.set_grant(ctx.set, revoked.id)
      assert id == revoked.id
    end

    test "a deleted set, and a set struct carrying another owner, are not found", ctx do
      grant = user_grant!(ctx.user.id)
      {:ok, second} = InferenceCredentials.create_set(ctx.user.id, "Second")
      {:ok, _} = InferenceCredentials.delete_set(second)

      assert {:error, :not_found} = InferenceCredentials.set_grant(second, grant.id)

      # The reload is by id and owner together: a forged struct reaches neither
      # the victim's set nor the forger's grant.
      forged = %{ctx.set | user_id: ctx.other.id}
      theirs = user_grant!(ctx.other.id)
      assert {:error, :not_found} = InferenceCredentials.set_grant(forged, theirs.id)
      assert is_nil(stored(ctx.set).chatgpt_grant_id)
    end

    test "no other write to a set can carry a grant along, and none drops it", ctx do
      grant = user_grant!(ctx.user.id)
      other_grant = user_grant!(ctx.user.id)
      {:ok, named} = InferenceCredentials.set_grant(ctx.set, grant.id)

      changeset =
        Credential.changeset(named, %{chatgpt_grant_id: other_grant.id, name: "Renamed"})

      refute Map.has_key?(changeset.changes, :chatgpt_grant_id)

      {:ok, _} = InferenceCredentials.put_credential_in(named, ctx.dek, :openai_api_key, "sk-own")
      {:ok, _} = InferenceCredentials.rename_set(named, "Renamed")
      assert stored(ctx.set).chatgpt_grant_id == grant.id
    end
  end

  describe "the database holds the same rule" do
    test "a set cannot be pointed at another owner's grant behind the changeset", ctx do
      foreign = user_grant!(ctx.other.id)

      assert_raise Postgrex.Error, ~r/inference_credentials_chatgpt_grant_id_fkey/, fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(c in Credential, where: c.id == ^ctx.set.id),
            set: [chatgpt_grant_id: foreign.id]
          )
        end)
      end
    end

    test "a set cannot be pointed at the deployment's grant", ctx do
      platform = connect!()

      assert_raise Postgrex.Error, ~r/inference_credentials_chatgpt_grant_id_fkey/, fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(c in Credential, where: c.id == ^ctx.set.id),
            set: [chatgpt_grant_id: platform.id]
          )
        end)
      end
    end

    test "deleting the account takes its sets and its grants together", ctx do
      grant = user_grant!(ctx.user.id)
      {:ok, _} = InferenceCredentials.set_grant(ctx.set, grant.id)
      keeps = user_grant!(ctx.other.id)

      Repo.delete!(ctx.user)

      refute Repo.get(Credential, ctx.set.id)
      refute Repo.get(Account, grant.id)
      assert Repo.get(Account, keeps.id)
    end
  end

  describe "a grant that sets name" do
    test "is not removed from under them, and says which sets", ctx do
      grant = user_grant!(ctx.user.id, %{name: "Named"})
      {:ok, personal} = InferenceCredentials.create_set(ctx.user.id, "Personal")
      {:ok, _} = InferenceCredentials.set_grant(ctx.set, grant.id)
      {:ok, _} = InferenceCredentials.set_grant(personal, grant.id)

      # Disconnect is the kill switch and is never blocked by configuration.
      assert :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)
      assert stored(ctx.set).chatgpt_grant_id == grant.id

      assert {:error, {:named_by_sets, ["Personal", "Work"]}} =
               ChatGPTAccounts.remove_for_user(grant.id, ctx.user.id)

      assert Repo.get(Account, grant.id)

      refute Enum.any?(
               Audit.list_recent_for_user(ctx.user.id),
               &(&1.action == "chatgpt_grant.removed")
             )

      {:ok, _} = InferenceCredentials.set_grant(stored(ctx.set), nil)

      assert {:error, {:named_by_sets, ["Personal"]}} =
               ChatGPTAccounts.remove_for_user(grant.id, ctx.user.id)

      {:ok, _} = InferenceCredentials.set_grant(stored(personal), nil)
      assert :ok = ChatGPTAccounts.remove_for_user(grant.id, ctx.user.id)
      refute Repo.get(Account, grant.id)
    end

    test "another account's set of the same name says nothing about this grant", ctx do
      grant = user_grant!(ctx.user.id)
      assert InferenceCredentials.set_names_for_grant(grant.id, ctx.other.id) == []
      assert InferenceCredentials.set_names_for_grant("not-a-uuid", ctx.user.id) == []

      {:ok, _} = InferenceCredentials.set_grant(ctx.set, grant.id)
      assert InferenceCredentials.set_names_for_grant(grant.id, ctx.user.id) == ["Work"]
      assert InferenceCredentials.set_names_for_grant(grant.id, ctx.other.id) == []
    end

    test "a set clearing a tombstone it names is allowed, which is how the user gets out", ctx do
      grant = user_grant!(ctx.user.id)
      {:ok, named} = InferenceCredentials.set_grant(ctx.set, grant.id)
      :ok = ChatGPTAccounts.disconnect_for_user(grant.id, ctx.user.id)

      assert {:ok, %{chatgpt_grant_id: nil}} = InferenceCredentials.set_grant(named, nil)
    end
  end
end
