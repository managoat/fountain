defmodule Fountain.Conversations.InferenceRotationTest do
  @moduledoc """
  A bound credential rotated in place reaches the conversation's state
  (#2602): unbrokered, the spawn env; brokered, the broker's rules. Codex
  does not rotate (its key is in `auth.json`), so nothing here moves it.
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

  test "codex does not rotate", %{user: user, dek: dek} do
    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "old-key-long-enough")

    state = state_for(user, :openai_api_key, "old-key-long-enough", "openai/gpt-5", "codex")

    {:ok, _} =
      InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "new-key-long-enough")

    assert {:error, :inference_source_changed} =
             InferenceCredentials.validate_source(user.id, state.inference_source)

    assert InferenceRotation.rotated(state) == nil
    assert {^state, false} = InferenceRotation.refresh_unbrokered(state)
    brokered = %{state | broker: %{}}
    assert {^brokered, false} = InferenceRotation.reread_brokered(brokered)
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
