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

      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")

      assert [%Credential{name: "Default", is_default: true}] =
               InferenceCredentials.list_sets(user.id)

      assert {:ok, %{anthropic_api_key: "sk-one"}} =
               InferenceCredentials.decrypted_for_user(user.id, dek)

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

    test "a new set holds nothing", %{user: user} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Empty")

      assert InferenceCredentials.status_for_set(set) ==
               Map.new(Credential.providers(), &{&1, false})
    end
  end

  describe "rename_set/3" do
    test "persists the new name and audits the previous and current names", %{user: user} do
      {:ok, set} = InferenceCredentials.create_set(user.id, "Work")

      assert {:ok, renamed} =
               InferenceCredentials.rename_set(set, "Client projects",
                 actor: "api_key:rename-test",
                 request_ip: "192.0.2.1"
               )

      assert renamed.id == set.id
      assert renamed.name == "Client projects"

      assert [%Credential{id: id, name: "Client projects", is_default: true}] =
               InferenceCredentials.list_sets(user.id)

      assert id == set.id
      assert InferenceCredentials.get_set(set.id, user.id).name == "Client projects"

      assert [event] =
               user.id
               |> Fountain.Audit.list_recent_for_user()
               |> Enum.filter(&(&1.action == "inference_credential_set.renamed"))

      assert event.resource_type == "inference_credential_set"
      assert event.resource_id == set.id
      assert event.actor == "api_key:rename-test"
      assert event.request_ip == "192.0.2.1"

      assert event.metadata == %{
               "name" => "Client projects",
               "was" => "Work",
               "now" => "Client projects"
             }
    end

    test "stale renames update the current name and audit its actual predecessor", %{user: user} do
      {:ok, stale} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, _} = InferenceCredentials.rename_set(stale, "Personal")
      assert {:ok, %{name: "Work"}} = InferenceCredentials.rename_set(stale, "Work")
      assert InferenceCredentials.get_set(stale.id, user.id).name == "Work"
      {:ok, _} = InferenceCredentials.rename_set(stale, "Personal")
      assert {:ok, %{name: "Client"}} = InferenceCredentials.rename_set(stale, "Client")

      events =
        user.id
        |> Fountain.Audit.list_recent_for_user()
        |> Enum.filter(&(&1.action == "inference_credential_set.renamed"))

      assert Enum.any?(
               events,
               &(&1.metadata == %{"name" => "Work", "was" => "Personal", "now" => "Work"})
             )

      assert Enum.any?(
               events,
               &(&1.metadata == %{"name" => "Client", "was" => "Personal", "now" => "Client"})
             )

      before = length(events)
      assert {:ok, %{name: "Client"}} = InferenceCredentials.rename_set(stale, "Client")
      assert audit_count(user, "inference_credential_set.renamed") == before
    end

    test "deleted and foreign tenant rows refuse stale renames without audit", %{user: user} do
      {:ok, _} = InferenceCredentials.create_set(user.id, "Default")
      {:ok, stale} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, _} = InferenceCredentials.delete_set(stale)
      assert {:error, :not_found} = InferenceCredentials.rename_set(stale, "Missing")
      other = insert_verified_user()
      {:ok, foreign} = InferenceCredentials.create_set(other.id, "Foreign")

      assert {:error, :not_found} =
               InferenceCredentials.rename_set(%{foreign | user_id: user.id}, "Stolen")

      assert InferenceCredentials.get_set(foreign.id, other.id).name == "Foreign"
      assert audit_count(user, "inference_credential_set.renamed") == 0
    end

    test "a duplicate name returns a name error without changing persistence or audit", %{
      user: user
    } do
      {:ok, work} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, personal} = InferenceCredentials.create_set(user.id, "Personal")
      before = audit_count(user, "inference_credential_set.renamed")

      assert {:error, changeset} = InferenceCredentials.rename_set(personal, work.name)
      assert "already names a credential set on this account" in errors_on(changeset).name
      assert InferenceCredentials.get_set(personal.id, user.id).name == "Personal"
      assert InferenceCredentials.get_set(work.id, user.id).name == "Work"
      assert audit_count(user, "inference_credential_set.renamed") == before
    end

    test "another account's name does not prevent a rename", %{user: user} do
      other = insert_verified_user()
      {:ok, _} = InferenceCredentials.create_set(other.id, "Personal")
      {:ok, set} = InferenceCredentials.create_set(user.id, "Work")

      assert {:ok, _} = InferenceCredentials.rename_set(set, "Personal")
      assert InferenceCredentials.get_set(set.id, user.id).name == "Personal"
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

  describe "default decisions use the current row" do
    test "a stale non-default struct cannot delete the newly promoted default", %{user: user} do
      {:ok, _first} = InferenceCredentials.create_set(user.id, "First")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Second")
      assert {:ok, _} = InferenceCredentials.set_default(second)

      assert {:error, :is_default} = InferenceCredentials.delete_set(second)
      assert InferenceCredentials.get_for_user(user.id).id == second.id
      assert length(InferenceCredentials.list_sets(user.id)) == 2
    end

    test "a stale default struct can promote itself again or be deleted after demotion", %{
      user: user
    } do
      {:ok, first} = InferenceCredentials.create_set(user.id, "First")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Second")
      assert {:ok, _} = InferenceCredentials.set_default(second)
      assert {:ok, _} = InferenceCredentials.set_default(first)
      assert InferenceCredentials.get_for_user(user.id).id == first.id

      assert {:ok, _} = InferenceCredentials.set_default(second)
      assert {:ok, _} = InferenceCredentials.delete_set(first)
      assert InferenceCredentials.get_for_user(user.id).id == second.id
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
