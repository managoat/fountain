defmodule Fountain.InferenceCredentialMutationTest do
  use Fountain.DataCase, async: true
  alias Fountain.{Audit, Crypto, InferenceCredentials}

  setup do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, default} = InferenceCredentials.create_set(user.id, "Default")
    {:ok, selected} = InferenceCredentials.create_set(user.id, "Selected")
    %{user: user, dek: dek, default: default, selected: selected}
  end

  test "clearing a stale empty set clears the committed key and audits its current name", f do
    {:ok, _} =
      InferenceCredentials.put_credential_in(f.selected, f.dek, :openai_api_key, "interleaved")

    {:ok, _} = InferenceCredentials.rename_set(f.selected, "Renamed")

    assert {:ok, cleared} =
             InferenceCredentials.put_credential_in(f.selected, f.dek, :openai_api_key, nil)

    assert cleared.openai_api_key_ciphertext == nil
    assert cleared.name == "Renamed"
    assert InferenceCredentials.get_set(f.selected.id, f.user.id).openai_api_key_ciphertext == nil

    assert [event] =
             Audit.list_recent_for_user(f.user.id)
             |> Enum.filter(&(&1.action == "inference_credential.delete"))

    assert event.metadata["set"] == "Renamed"
  end

  test "deleted or foreign selected sets refuse writes and clears without audit", f do
    {:ok, _} = InferenceCredentials.delete_set(f.selected)
    before = length(Audit.list_recent_for_user(f.user.id))

    for value <- [nil, "replacement"] do
      assert {:error, :not_found} =
               InferenceCredentials.put_credential_in(f.selected, f.dek, :openai_api_key, value)
    end

    other = insert_verified_user()
    {:ok, foreign} = InferenceCredentials.create_set(other.id, "Foreign")

    assert {:error, :not_found} =
             InferenceCredentials.put_credential_in(
               %{foreign | user_id: f.user.id},
               f.dek,
               :openai_api_key,
               "replacement"
             )

    assert length(Audit.list_recent_for_user(f.user.id)) == before
    assert InferenceCredentials.get_set(foreign.id, other.id).openai_api_key_ciphertext == nil
  end
end
