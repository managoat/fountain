defmodule Fountain.InferenceCredentialRecordTest do
  @moduledoc """
  One inference credential record per user (ADR 0008; named sets retired by
  ADR 0053's 2026-10-14 addendum).
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

  test "the first write creates the record and later writes land in it", %{
    user: user,
    dek: dek
  } do
    assert InferenceCredentials.get_for_user(user.id) == nil

    {:ok, first} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")
    {:ok, second} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-two")

    assert first.id == second.id
    assert Repo.aggregate(from(c in Credential, where: c.user_id == ^user.id), :count) == 1

    assert {:ok, %{anthropic_api_key: "sk-one", openai_api_key: "sk-two"}} =
             InferenceCredentials.decrypted_for_user(user.id, dek)

    assert %{anthropic_api_key: true, openai_api_key: true, gemini_api_key: false} =
             InferenceCredentials.status_for_user(user.id)
  end

  # A concurrent first write cannot leave two.
  test "a second record for the same user is refused", %{user: user, dek: dek} do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")

    assert {:error, changeset} =
             %Credential{}
             |> Credential.changeset(%{user_id: user.id})
             |> Repo.insert()

    assert changeset.errors[:user_id]
  end

  test "the record is tenant-scoped", %{user: user, dek: dek} do
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")
    other = insert_verified_user()

    assert InferenceCredentials.get_for_user(other.id) == nil
    assert InferenceCredentials.status_for_user(other.id).anthropic_api_key == false
  end
end
