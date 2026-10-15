defmodule Fountain.Conversations.InferenceRotationTest do
  @moduledoc """
  A bound credential rotated in place reaches the conversation's state
  (#2602): unbrokered, the spawn env, and on codex its `auth.json`;
  brokered, the broker's rules.
  """
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Broker, Crypto, InferenceCredentials}
  alias Fountain.Conversations.{Egress, InferenceRotation, Redaction}

  setup do
    user = insert_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    %{user: user, dek: dek}
  end

  defp state_for(user, kind, value, model, runtime) do
    {:ok, source, creds} = InferenceCredentials.resolve(user.id, model, runtime)
    assert creds[kind] == value
    name = Map.fetch!(InferenceCredentials.env_names(), kind)

    %{
      conversation_id: Ecto.UUID.generate(),
      user_id: user.id,
      tenant_key: nil,
      broker: nil,
      inference_source: source,
      inference_credentials: creds,
      env_credentials: creds,
      handle: Managoat.Sandbox.Sprites.build_handle("rotation-test"),
      sprite_env: [{name, value}, {"OTHER", value <> "-not-it"}, {"KEPT", "x"}],
      brokered: %{},
      tenant_keys: [],
      secret_sources: nil,
      broker_bindings: %{},
      broker_network: :unrestricted
    }
  end

  test "an unbrokered rotation swaps the value in the spawn env and says so", %{
    user: user,
    dek: dek
  } do
    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "old-key-long-enough")

    state =
      state_for(
        user,
        :anthropic_api_key,
        "old-key-long-enough",
        "anthropic/claude-sonnet-5",
        "claude"
      )

    assert {^state, false} = InferenceRotation.refresh_unbrokered(state)

    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "new-key-long-enough")

    assert {next, true} = InferenceRotation.refresh_unbrokered(state)

    assert next.sprite_env == [
             {"ANTHROPIC_API_KEY", "new-key-long-enough"},
             {"OTHER", "old-key-long-enough-not-it"},
             {"KEPT", "x"}
           ]

    assert next.inference_credentials.anthropic_api_key == "new-key-long-enough"
    assert next.env_credentials.anthropic_api_key == "new-key-long-enough"
    assert next.inference_source == state.inference_source
    assert "new-key-long-enough" in Redaction.lookup(state.conversation_id)
    assert {_, false} = InferenceRotation.refresh_unbrokered(next)
  end

  test "an edit to another key of the record moves nothing", %{user: user, dek: dek} do
    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "old-key-long-enough")

    state =
      state_for(
        user,
        :anthropic_api_key,
        "old-key-long-enough",
        "anthropic/claude-sonnet-5",
        "claude"
      )

    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :gemini_api_key, "g")

    assert :ok = InferenceCredentials.validate_source(user.id, state.inference_source)
    assert {^state, false} = InferenceRotation.refresh_unbrokered(state)
  end

  describe "codex" do
    setup %{user: user, dek: dek} do
      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "old-key-long-enough")

      state = state_for(user, :openai_api_key, "old-key-long-enough", "openai/gpt-5", "codex")

      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "new-key-long-enough")

      %{state: state}
    end

    test "an unbrokered rotation rewrites auth.json before anything moves", %{
      user: user,
      state: state
    } do
      assert :ok = InferenceCredentials.validate_source(user.id, state.inference_source)
      test = self()

      expect(Managoat.Sandbox, :write_file, fn handle, path, data, opts ->
        send(test, {:wrote, handle, path, data, opts})
        :ok
      end)

      assert {next, true} = InferenceRotation.refresh_unbrokered(state)
      assert_received {:wrote, handle, path, data, [mode: 0o600]}
      assert handle == state.handle
      assert path == Managoat.Runtimes.Codex.auth_path()

      assert Jason.decode!(data) == %{
               "auth_mode" => "apikey",
               "OPENAI_API_KEY" => "new-key-long-enough"
             }

      assert {"OPENAI_API_KEY", "new-key-long-enough"} in next.sprite_env
      assert next.inference_credentials.openai_api_key == "new-key-long-enough"
      assert "new-key-long-enough" in Redaction.lookup(state.conversation_id)
      assert {_, false} = InferenceRotation.refresh_unbrokered(next)
    end

    test "a failed auth.json write refuses and moves nothing", %{state: state} do
      expect(Managoat.Sandbox, :write_file, fn _, _, _, _ -> {:error, :timeout} end)

      assert {:error, {:codex_auth_write, :timeout}} =
               InferenceRotation.refresh_unbrokered(state)

      refute "new-key-long-enough" in Redaction.lookup(state.conversation_id)

      # The state the caller keeps still holds the old value, so the next
      # turn tries the write again.
      expect(Managoat.Sandbox, :write_file, fn _, _, _, _ -> :ok end)
      assert {_, true} = InferenceRotation.refresh_unbrokered(state)
    end

    test "a brokered rotation reaches the rules and leaves auth.json alone", %{
      dek: dek,
      state: state
    } do
      placeholder = Broker.placeholder("OPENAI_API_KEY")

      state = %{
        state
        | tenant_key: dek,
          broker: %{
            vault: "c-test",
            token: "av_live",
            expires_at: DateTime.add(DateTime.utc_now(), 3600)
          },
          brokered: %{"OPENAI_API_KEY" => "old-key-long-enough"},
          env_credentials: %{openai_api_key: placeholder},
          sprite_env: [{"OPENAI_API_KEY", placeholder}]
      }

      test = self()

      stub(Broker, :refresh, fn _conv, brokered, _bindings, _opts ->
        send(test, {:rules, brokered})
        {:ok, 1}
      end)

      reject(&Managoat.Sandbox.write_file/4)

      assert {next, false} = Egress.refresh_before_turn(state)
      assert_received {:rules, %{"OPENAI_API_KEY" => "new-key-long-enough"}}
      assert next.sprite_env == [{"OPENAI_API_KEY", placeholder}]
      assert {^next, false} = InferenceRotation.refresh_unbrokered(next)
    end
  end

  test "a ChatGPT subscription does not rotate in place" do
    source = %InferenceCredentials.Source{
      kind: :codex_chatgpt_access_token,
      scope: :grant,
      identity: "chatgpt:#{Ecto.UUID.generate()}",
      revision: "acct-1",
      runtime: "codex",
      model: "openai/gpt-5"
    }

    dumped = InferenceCredentials.Source.dump(source)
    refute InferenceCredentials.Source.rotates?(source)

    refute InferenceCredentials.Source.rotation?(
             dumped,
             Map.put(dumped, "revision", "acct-2")
           )
  end

  test "a brokered rotation rewrites the live rules and keeps the token", %{
    user: user,
    dek: dek
  } do
    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "old-key-long-enough")

    state =
      state_for(
        user,
        :anthropic_api_key,
        "old-key-long-enough",
        "anthropic/claude-sonnet-5",
        "claude"
      )

    state = %{
      state
      | tenant_key: dek,
        broker: %{
          vault: "c-test",
          token: "av_live",
          expires_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        brokered: %{"ANTHROPIC_API_KEY" => "old-key-long-enough"},
        env_credentials: %{anthropic_api_key: "__placeholder__"},
        sprite_env: [{"ANTHROPIC_API_KEY", "__placeholder__"}]
    }

    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "new-key-long-enough")

    test = self()

    stub(Broker, :refresh, fn _conv, brokered, _bindings, _opts ->
      send(test, {:rules, brokered})
      assert "new-key-long-enough" in Redaction.lookup(state.conversation_id)
      {:ok, 1}
    end)

    stub(Broker, :prepare, fn _, _, _, _ -> flunk("a live rewrite needs no new session") end)

    assert {next, false} = Egress.refresh_before_turn(state)
    assert_received {:rules, %{"ANTHROPIC_API_KEY" => "new-key-long-enough"}}
    assert next.broker.token == "av_live"
    assert next.sprite_env == state.sprite_env
    assert next.inference_credentials.anthropic_api_key == "new-key-long-enough"
    assert {^next, false} = InferenceRotation.refresh_unbrokered(next)
  end

  test "a vault secret rotated mid-turn reaches the live rules", %{user: user, dek: dek} do
    vault = insert_vault(user_id: user.id)

    put =
      &Fountain.Vaults.upsert_secret(vault, %{"key" => "ANTHROPIC_API_KEY", "value" => &1}, dek)

    {:ok, _} = put.("old-vault-key-long-enough")

    {:ok, source, creds} =
      InferenceCredentials.resolve(user.id, "anthropic/claude-sonnet-5", "claude",
        vault_id: vault.id
      )

    state = %{
      conversation_id: Ecto.UUID.generate(),
      user_id: user.id,
      tenant_key: dek,
      broker: %{vault: "c-test", token: "av_live", expires_at: nil},
      inference_source: source,
      inference_credentials: creds,
      env_credentials: %{anthropic_api_key: "__placeholder__"},
      sprite_env: [],
      brokered: %{"ANTHROPIC_API_KEY" => "old-vault-key-long-enough"},
      tenant_keys: [],
      secret_sources: %{environment_id: nil, vault_id: vault.id},
      broker_bindings: %{},
      broker_network: :unrestricted
    }

    {:ok, _} = put.("new-vault-key-long-enough")
    test = self()

    stub(Broker, :refresh, fn _conv, brokered, _bindings, _opts ->
      send(test, {:rules, brokered})
      {:ok, 1}
    end)

    next = Egress.refresh_live(state)
    assert_received {:rules, %{"ANTHROPIC_API_KEY" => "new-vault-key-long-enough"}}
    assert next.inference_credentials.anthropic_api_key == "new-vault-key-long-enough"
    assert next.broker == state.broker
  end
end
