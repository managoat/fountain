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

  # A secret's value is the tenant's own text. One that mentions the reserved
  # name names nothing; one that could stand for the managed credential does.
  describe "a secret's value" do
    @mentions [
      "#!/bin/sh\n# codex reads CODEX_CHATGPT_ACCESS_TOKEN from its env\nexec codex \"$@\"",
      ~s({"unset": ["OPENAI_API_KEY", "CODEX_CHATGPT_ACCESS_TOKEN"]}),
      "echo ${CODEX_CHATGPT_ACCESS_TOKEN:-none}",
      "codex_chatgpt_access_token_notes.txt",
      "__codex_chatgpt_access_token_nothex__",
      "_codex_chatgpt_access_token_"
    ]

    test "may mention the reserved name: as a value, in a write and in a compile" do
      dek = :crypto.strong_rand_bytes(32)

      for value <- @mentions do
        refute Reserved.value_conflict?(value)
        # As a key, a binding field or a network pattern it is still refused.
        assert Reserved.conflict?(value)

        for {schema, owner_field} <- [{Secret, "environment_id"}, {VaultSecret, "vault_id"}] do
          attrs = %{owner_field => Ecto.UUID.generate(), "key" => "SETUP", "value" => value}
          assert schema.changeset(struct(schema), attrs, dek).valid?
        end

        assert {:ok, _} =
                 Fountain.Broker.Native.ProtectedCompiler.compile(
                   %{"SETUP" => value},
                   %{},
                   :unrestricted
                 )
      end
    end

    test "may not stand for the managed credential" do
      grant = Reserved.placeholder(Ecto.UUID.generate())

      for value <- [
            Reserved.key(),
            " codex_chatgpt_access_token\n",
            Reserved.placeholder(),
            grant,
            String.upcase(grant),
            "Bearer " <> grant,
            ~s({"Authorization": "Bearer sk-#{Reserved.placeholder()}"}),
            "{{ CODEX_CHATGPT_ACCESS_TOKEN }}",
            "Bearer {{CODEX_CHATGPT_ACCESS_TOKEN}}",
            %Fountain.ChatGPTAccounts.Grant{
              access_token: "bearer",
              source: %{account_id: "acct"}
            },
            {:nested, grant}
          ] do
        assert Reserved.value_conflict?(value)

        assert {:error, :managed_credential_conflict} =
                 Fountain.Broker.Native.ProtectedCompiler.compile(
                   %{"ALIAS" => value},
                   %{},
                   :unrestricted
                 )
      end
    end

    test "a key is still held to the strict rule, whatever its value" do
      for key <- ["CODEX_CHATGPT_ACCESS_TOKEN_2", "MY_CODEX_CHATGPT_ACCESS_TOKEN"] do
        assert {:error, :managed_credential_conflict} =
                 Fountain.Broker.Native.ProtectedCompiler.compile(
                   %{key => "ordinary"},
                   %{},
                   :unrestricted
                 )

        cs =
          Secret.changeset(
            %Secret{},
            %{"environment_id" => Ecto.UUID.generate(), "key" => key, "value" => "ordinary"},
            :crypto.strong_rand_bytes(32)
          )

        assert errors_on(cs).key == ["is reserved for managed ChatGPT credentials"]
      end
    end
  end

  # ADR 0060 decision 6: a placeholder per grant. `conflict?/1` is a
  # case-insensitive substring match on the reserved key, which every one of
  # them contains, so no list of grants is consulted and none can be missed.
  describe "per-grant placeholders" do
    test "every grant's placeholder is reserved, wherever and however it is written" do
      for _ <- 1..20 do
        placeholder = Reserved.placeholder(Ecto.UUID.generate())
        assert Reserved.placeholder?(placeholder)
        refute placeholder == Reserved.placeholder()
        assert Managoat.Broker.Injector.valid_placeholder?(placeholder)

        for value <- [
              placeholder,
              String.upcase(placeholder),
              "Bearer " <> placeholder,
              %{"Authorization" => "Bearer " <> placeholder},
              %{placeholder => "as a key"},
              [{:nested, ["deep", placeholder]}]
            ] do
          assert Reserved.conflict?(value)
        end
      end
    end

    test "the same grant always gets the same placeholder, whatever the spelling of its id" do
      id = Ecto.UUID.generate()
      assert Reserved.placeholder(id) == Reserved.placeholder(String.upcase(id))
      refute Reserved.placeholder(id) == Reserved.placeholder(Ecto.UUID.generate())
    end

    test "placeholder?/1 is exact: not the legacy one, not a lookalike, not a secret" do
      refute Reserved.placeholder?(Reserved.placeholder())
      refute Reserved.placeholder?("__codex_chatgpt_access_token_nothex__")
      refute Reserved.placeholder?("x" <> Reserved.placeholder(Ecto.UUID.generate()))
      refute Reserved.placeholder?("sk-a-real-key")
      refute Reserved.placeholder?(nil)
    end

    test "writes refuse a grant's placeholder as they refuse the legacy one" do
      user = insert_verified_user()
      placeholder = Reserved.placeholder(Ecto.UUID.generate())

      assert {:error, cs} =
               SecretBindings.create_binding(user.id, %{
                 "key" => "OTHER",
                 "host" => "attacker.example",
                 "auth_type" => "custom",
                 "headers" => %{"X-Leak" => "Bearer " <> placeholder}
               })

      assert Enum.any?(cs.errors, fn {_field, {message, _}} ->
               message == "is reserved for managed ChatGPT credentials"
             end)

      for {schema, owner_field} <- [{Secret, "environment_id"}, {VaultSecret, "vault_id"}] do
        cs =
          schema.changeset(
            struct(schema),
            %{owner_field => Ecto.UUID.generate(), "key" => "ALIAS", "value" => placeholder},
            :crypto.strong_rand_bytes(32)
          )

        refute cs.valid?
      end
    end

    test "split_inference/2 takes no custody of one: nothing brokered, no rule that names it" do
      placeholder = Reserved.placeholder(Ecto.UUID.generate())
      creds = %{codex_chatgpt_access_token: placeholder, anthropic_api_key: "sk-ant"}

      assert {split, brokered, implicit} = Fountain.Broker.split_inference(creds)
      assert split.codex_chatgpt_access_token == placeholder
      assert brokered == %{"ANTHROPIC_API_KEY" => "sk-ant"}
      assert Map.keys(implicit) == ["ANTHROPIC_API_KEY"]
    end
  end
end
