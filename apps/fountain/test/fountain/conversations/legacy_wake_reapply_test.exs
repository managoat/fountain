defmodule Fountain.Conversations.LegacyWakeReapplyTest do
  use Fountain.ConversationServerCase

  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.Conversations.{InferenceBinding, Provisioning, Reapply, SpriteEnv, TurnMachine}
  alias Fountain.InferenceCredentials.Source

  for runtime <- ["claude", "codex"] do
    test "#{runtime} legacy wake refuses a reapply committed during provider I/O", _ do
      c = fixture(unquote(runtime))
      owner = self()

      expect(Provisioning, :write_env_file, fn _, _ ->
        # Initial resolution has bound the legacy row; the actor still holds
        # its original nil-source snapshot across this provider boundary.
        current = Repo.reload!(c.conv)
        assert current.inference_source == Source.dump(c.source)
        assert {:ok, reapplied} = reapply(c, current)
        send(owner, {:reapplied, reapplied})
        :ok
      end)

      {_pid, ref, :stopped} = start_server(c.conv)
      assert :normal = assert_stopped(ref)
      refute_received {:runtime_prepared, _}
      assert_received {:reapplied, reapplied}
      assert_usable_on_next_wake(c, reapplied)
    end

    test "#{runtime} early stale resolution does not fail the reapplied legacy row", _ do
      c = fixture(unquote(runtime))
      owner = self()

      stub(Conversations, :_unsafe_get_conversation, fn id ->
        Mimic.call_original(Conversations, :_unsafe_get_conversation, [id])
      end)

      expect(Conversations, :_unsafe_get_conversation, fn id ->
        conv = Mimic.call_original(Conversations, :_unsafe_get_conversation, [id])
        assert {:ok, reapplied} = reapply(c, conv)
        send(owner, {:reapplied, reapplied})
        conv
      end)

      {_pid, ref, :stopped} = start_server(c.conv)
      assert :normal = assert_stopped(ref)
      refute_received {:runtime_prepared, _}
      assert_received {:reapplied, reapplied}
      # Reapply intentionally leaves a genuinely legacy selection unbound.
      assert Repo.reload!(c.conv).inference_source == nil
      assert_usable_on_next_wake(c, reapplied)
    end

    test "#{runtime} reservations allow initial/current bindings and refuse stale snapshots", _ do
      c = fixture(unquote(runtime))
      assert c.conv.inference_source == nil
      assert :ok = InferenceBinding.reserve(c.conv, c.source)
      bound = Repo.reload!(c.conv)
      # Reusing the original legacy snapshot is harmless only for the same
      # persisted configuration and source, including its full context.
      assert :ok = InferenceBinding.reserve(c.conv, c.source)

      assert {:error, :inference_source_changed} =
               InferenceBinding.reserve(c.conv, %{c.source | environment_id: c.other.id})

      assert {:ok, reapplied} = reapply(c, bound)
      machine = Repo.reload!(c.sandbox)
      persisted = Repo.reload!(c.conv)

      for stale <- [c.conv, bound] do
        assert {:error, :configuration_changed} = InferenceBinding.reserve(stale, c.source)

        assert {:error, :configuration_changed} =
                 SpriteEnv.resolve_inference(stale, c.agent, c.env, nil)
      end

      assert {:error, :inference_source_changed} = InferenceBinding.reserve(reapplied, c.source)
      assert Repo.reload!(c.conv) == persisted
      assert Repo.reload!(c.sandbox) == machine
      assert :ok = InferenceBinding.reserve(reapplied, Source.load(reapplied.inference_source))
    end
  end

  defp fixture(runtime) do
    stub_happy_sprite()
    owner = self()

    stub(Provisioning, :prepare_runtime_sprite, fn _, _, _, _, pairs ->
      send(owner, {:runtime_prepared, pairs})
      :ok
    end)

    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)

    {kind, model} =
      if runtime == "codex",
        do: {:openai_api_key, "openai/gpt-5"},
        else: {:anthropic_api_key, "anthropic/claude-sonnet-5"}

    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, kind, "same-key")
    env = insert_env(user_id: user.id)

    other =
      insert_env(
        user_id: user.id,
        packages: env.packages,
        repositories: env.repositories,
        setup_script: env.setup_script,
        env_vars: %{"WHO" => "new-environment"}
      )

    agent =
      insert_agent(user_id: user.id, runtime: runtime, model: model, environment_id: env.id)

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, model, runtime, environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        mode: "ephemeral",
        status: "ready",
        build_fingerprint: Reapply.fingerprint(env)
      )

    if runtime == "codex" do
      # Codex machine auth outlives conversation bindings. A ready machine
      # already holding this identity can safely admit an unbound legacy row.
      sandbox
      |> Ecto.Changeset.change(codex_inference_source: Source.dump(source))
      |> Repo.update!()
    end

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    %{conv: conv, sandbox: sandbox, agent: agent, env: env, other: other, source: source}
  end

  defp reapply(c, conv),
    do: Reapply.reapply_conversation(conv, %{"environment_id" => c.other.id})

  defp assert_usable_on_next_wake(c, reapplied) do
    current = Repo.reload!(c.conv)
    assert current.status == "idle"
    assert current.environment_id == c.other.id
    assert current.configuration_revision == reapplied.configuration_revision
    assert current.inference_source == reapplied.inference_source
    assert Repo.reload!(c.sandbox).status == "ready"

    {pid, _ref, :alive} = start_server(current)
    assert_received {:runtime_prepared, pairs}
    assert {"WHO", "new-environment"} in pairs
    state = :sys.get_state(pid)
    assert state.configuration_revision == current.configuration_revision
    assert state.inference_source.environment_id == c.other.id
    assert state.inference_source.identity == c.source.identity
    assert Repo.reload!(c.conv).inference_source == Source.dump(state.inference_source)

    assert {:ok, _, turn} =
             TurnMachine.open(
               current.id,
               current.sandbox_id,
               "next prompt",
               c.agent,
               state.configuration_revision,
               state.inference_source
             )

    assert turn.inference_source == Source.dump(state.inference_source)
  end
end
