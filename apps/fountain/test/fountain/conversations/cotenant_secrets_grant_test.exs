defmodule Fountain.Conversations.CotenantSecretsGrantTest do
  # #2513: a codex co-tenant on a ChatGPT subscription (ADR 0060) resolves to
  # the grant's placeholder, never its bearer, and the bearer never enters
  # the sandbox. There is nothing of it to register, and the placeholder is
  # not a secret (#2366). Not async: a grant is selected only on a brokered
  # deployment, which is application configuration.
  use Fountain.DataCase, async: false

  import Fountain.ChatGPTFixtures

  alias Fountain.Conversations.{CotenantSecrets, InferenceResolution, Redaction}
  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.InferenceCredentials.Source

  setup do
    restore =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- restore do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    :ok
  end

  test "a codex co-tenant on a subscription registers no placeholder and no key" do
    user = insert_active_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    grant = user_grant!(user.id, %{name: "Work"})
    {:ok, set} = InferenceCredentials.create_set(user.id, "Subscription")

    {:ok, set} =
      InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-set-own-2513")

    {:ok, set} = InferenceCredentials.set_grant(set, grant.id)

    codex_agent =
      insert_agent(user_id: user.id, runtime: "codex", inference_credential_id: set.id)

    claude_agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    {:ok, source, _} = InferenceResolution.select(user.id, codex_agent, [])
    assert source.scope == :grant

    claude =
      insert_conversation(user_id: user.id, agent: claude_agent, sandbox: sandbox, status: "idle")

    insert_conversation(
      user_id: user.id,
      agent: codex_agent,
      sandbox: sandbox,
      status: "idle",
      inference_source: Source.dump(source)
    )

    on_exit(fn -> Redaction.delete(claude.id) end)

    # Resolved, not skipped on an error: no warning.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert CotenantSecrets.register(claude.id, sandbox.id) == :mixed
      end)

    refute log =~ "not readable"

    registered = Redaction.lookup(claude.id)
    refute Fountain.ChatGPTAccounts.Reserved.placeholder(grant.id) in registered
    refute Enum.any?(registered, &Fountain.ChatGPTAccounts.Reserved.placeholder?/1)
    # The grant outranks the set's own key, which codex was never handed.
    refute "sk-set-own-2513" in registered
  end
end
