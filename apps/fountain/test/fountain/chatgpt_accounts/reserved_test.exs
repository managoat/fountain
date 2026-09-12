defmodule Fountain.ChatGPTAccounts.ReservedTest do
  use Fountain.DataCase, async: true

  alias Fountain.ChatGPTAccounts.Reserved
  alias Fountain.Environments.Secret
  alias Fountain.SecretBindings
  alias Fountain.Vaults.VaultSecret

  test "binding creates and updates reject managed references without echoing values" do
    user = insert_verified_user()

    attrs = %{
      "key" => "OTHER",
      "host" => "attacker.example",
      "auth_type" => "custom",
      "headers" => %{"X-Key" => "{{ OTHER }}"}
    }

    assert {:ok, binding} = SecretBindings.create_binding(user.id, attrs)

    for changes <- [
          %{"key" => Reserved.key()},
          %{"headers" => %{"X-Leak" => "Bearer {{ CODEX_CHATGPT_ACCESS_TOKEN }}"}},
          %{"headers" => %{"X-Leak" => Reserved.placeholder()}},
          %{"auth_type" => "api_key", "prefix" => Reserved.placeholder()}
        ] do
      assert {:error, cs} = SecretBindings.create_binding(user.id, Map.merge(attrs, changes))

      assert Enum.any?(cs.errors, fn {_field, {message, _}} ->
               message == "is reserved for managed ChatGPT credentials"
             end)

      assert {:error, _} = SecretBindings.update_binding(binding, changes)
    end

    assert [^binding] = SecretBindings.list_bindings(user.id)
  end

  test "updates revalidate pre-existing managed binding rows and permit repair or removal" do
    user = insert_verified_user()

    binding =
      Repo.insert!(%SecretBindings.Binding{
        user_id: user.id,
        key: Reserved.key(),
        host: "attacker.example",
        auth_type: "bearer"
      })

    assert {:error, cs} = SecretBindings.update_binding(binding, %{"host" => "another.example"})
    assert errors_on(cs).key == ["is reserved for managed ChatGPT credentials"]
    assert {:ok, repaired} = SecretBindings.update_binding(binding, %{"key" => "ORDINARY"})
    assert {:ok, _} = SecretBindings.delete_binding(repaired)
  end

  test "environment and vault writes reserve the key and prevent placeholder aliases" do
    dek = :crypto.strong_rand_bytes(32)

    for {schema, owner_field} <- [{Secret, "environment_id"}, {VaultSecret, "vault_id"}] do
      base = %{
        owner_field => Ecto.UUID.generate(),
        "key" => "ORDINARY",
        "value" => "ordinary-value"
      }

      assert schema.changeset(struct(schema), base, dek).valid?

      for attrs <- [
            Map.put(base, "key", Reserved.key()),
            Map.put(base, "value", "Bearer " <> Reserved.placeholder())
          ] do
        cs = schema.changeset(struct(schema), attrs, dek)
        refute cs.valid?

        assert Enum.any?(cs.errors, fn {_field, {message, _}} ->
                 message == "is reserved for managed ChatGPT credentials"
               end)
      end
    end
  end
end
