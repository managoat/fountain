defmodule Fountain.InferenceCredentialSetsTest do
  @moduledoc """
  An account holds several named credential sets, exactly one of them the
  default (ADR 0053 decision 1).

  The property that matters most here is the boring one: an account that
  never makes a second set behaves exactly as it did when this table held one
  row per user. Every read that used to mean "the row" now means "the default
  set", and the migration made every existing row a default set, so there is
  no account for which the answer moves.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Credential

  setup do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    %{user: user, dek: dek}
  end

  describe "the account that never opens the feature" do
    test "put_credential creates the default set and reads back through it", %{
      user: user,
      dek: dek
    } do
      assert InferenceCredentials.list_sets(user.id) == []
      refute InferenceCredentials.has_any_credential?(user.id)

      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")

      assert [%Credential{name: "Default", is_default: true}] =
               InferenceCredentials.list_sets(user.id)

      assert {:ok, %{anthropic_api_key: "sk-one"}} =
               InferenceCredentials.decrypted_for_user(user.id, dek)

      assert InferenceCredentials.has_any_credential?(user.id)
      assert %{anthropic_api_key: true, openai_api_key: false} = status(user)
    end

    test "a second write lands in the same set rather than making another", %{
      user: user,
      dek: dek
    } do
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-two")

      assert [set] = InferenceCredentials.list_sets(user.id)
      assert %{anthropic_api_key: true, openai_api_key: true} = status(user)
      assert set.is_default
    end
  end

  describe "create_set/3" do
    test "the first set an account gets is its default, whoever asked", %{user: user} do
      {:ok, first} = InferenceCredentials.create_set(user.id, "Work")
      assert first.is_default
      assert InferenceCredentials.get_for_user(user.id).id == first.id

      {:ok, second} = InferenceCredentials.create_set(user.id, "Personal")
      refute second.is_default
      assert InferenceCredentials.get_for_user(user.id).id == first.id
    end

    test "a name is required and unique within the account, not across accounts", %{user: user} do
      {:ok, _} = InferenceCredentials.create_set(user.id, "Work")

      assert {:error, changeset} = InferenceCredentials.create_set(user.id, "Work")
      assert "already names a credential set on this account" in errors_on(changeset).name

      assert {:error, changeset} = InferenceCredentials.create_set(user.id, "")
      assert changeset.errors[:name]

      other = insert_verified_user()
      assert {:ok, _} = InferenceCredentials.create_set(other.id, "Work")
    end

    test "a new set holds nothing, and does not make the account look connected", %{user: user} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Empty")

      assert InferenceCredentials.status_for_set(set) ==
               Map.new(Credential.providers(), &{&1, false})

      refute InferenceCredentials.has_any_credential?(user.id)
    end
  end

  describe "set_default/2" do
    setup %{user: user} do
      {:ok, first} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Personal")
      %{first: first, second: second}
    end

    test "moves the flag, and there is never more than one", %{
      user: user,
      first: first,
      second: second
    } do
      {:ok, promoted} = InferenceCredentials.set_default(second)
      assert promoted.is_default

      sets = InferenceCredentials.list_sets(user.id)
      assert Enum.count(sets, & &1.is_default) == 1
      assert InferenceCredentials.get_for_user(user.id).id == second.id
      refute Enum.find(sets, &(&1.id == first.id)).is_default
    end

    test "the default comes first in list_sets, then by name", %{user: user, second: second} do
      {:ok, _} = InferenceCredentials.create_set(user.id, "Alpha")
      {:ok, _} = InferenceCredentials.set_default(second)

      assert ["Personal", "Alpha", "Work"] =
               user.id |> InferenceCredentials.list_sets() |> Enum.map(& &1.name)
    end

    # ADR 0013: a trail that logs attempts as changes is worse than no trail.
    test "promoting the set that is already default records nothing", %{user: user, first: first} do
      before = audit_count(user, "inference_credential_set.default_changed")
      assert {:ok, ^first} = InferenceCredentials.set_default(first)
      assert audit_count(user, "inference_credential_set.default_changed") == before
    end
  end

  describe "delete_set/2" do
    test "refuses the default: something has to answer which credential runs the account",
         %{user: user} do
      {:ok, only} = InferenceCredentials.create_set(user.id, "Work")

      assert {:error, :is_default} = InferenceCredentials.delete_set(only)
      assert [_] = InferenceCredentials.list_sets(user.id)
    end

    test "takes a set that is not the default, and the credential goes with it", %{
      user: user,
      dek: dek
    } do
      {:ok, _default} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Personal")

      second
      |> Ecto.Changeset.change(anthropic_api_key_ciphertext: Crypto.encrypt("sk-gone", dek))
      |> Repo.update!()

      assert {:ok, _} = InferenceCredentials.delete_set(second)
      assert ["Work"] = user.id |> InferenceCredentials.list_sets() |> Enum.map(& &1.name)
      refute InferenceCredentials.has_any_credential?(user.id)
    end

    test "promoting another first is how the old default goes", %{user: user} do
      {:ok, first} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Personal")

      assert {:error, :is_default} = InferenceCredentials.delete_set(first)
      {:ok, _} = InferenceCredentials.set_default(second)

      assert {:ok, _} = InferenceCredentials.delete_set(Repo.reload!(first))
      assert ["Personal"] = user.id |> InferenceCredentials.list_sets() |> Enum.map(& &1.name)
    end
  end

  describe "has_any_credential?/1 across sets" do
    # The onboarding nag and the dashboard read this. Asking only the default
    # set would put the nag back in front of an account whose only key lives
    # in a set they made for one agent.
    test "a key in any set counts", %{user: user, dek: dek} do
      {:ok, _default} = InferenceCredentials.create_set(user.id, "Empty default")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Has the key")

      refute InferenceCredentials.has_any_credential?(user.id)

      second
      |> Ecto.Changeset.change(anthropic_api_key_ciphertext: Crypto.encrypt("sk", dek))
      |> Repo.update!()

      assert InferenceCredentials.has_any_credential?(user.id)
      # And the default set is still what status_for_user/1 reports on.
      assert %{anthropic_api_key: false} = status(user)
    end
  end

  describe "get_set/2" do
    test "is tenant-scoped", %{user: user} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Work")

      assert InferenceCredentials.get_set(set.id, user.id).id == set.id
      assert InferenceCredentials.get_set(set.id, insert_verified_user().id) == nil
    end
  end

  defp status(user), do: InferenceCredentials.status_for_user(user.id)

  defp audit_count(user, action) do
    user.id
    |> Fountain.Audit.list_recent_for_user()
    |> Enum.count(&(&1.action == action))
  end
end
