defmodule Fountain.Conversations.ConversationServerInferenceBindingTest do
  use Fountain.ConversationServerCase

  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.InferenceCredentials.Source

  setup do
    stub_happy_sprite()
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)

    {:ok, default} =
      InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "default-key")

    {:ok, selected} = InferenceCredentials.create_set(user.id, "Selected")

    {:ok, selected} =
      InferenceCredentials.put_credential_in(selected, dek, :openai_api_key, "selected-key")

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "codex",
        model: "openai/gpt-5",
        inference_credential_id: selected.id
      )

    %{user: user, dek: dek, default: default, selected: selected, agent: agent}
  end

  test "the real actor reads the selected set and persists its resolved identity", ctx do
    conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent)
    {pid, _ref, :alive} = start_server(conv)
    state = :sys.get_state(pid)
    assert state.inference_credentials == %{openai_api_key: "selected-key"}
    assert state.inference_source.set_id == ctx.selected.id
    assert Repo.reload!(conv).inference_source == Source.dump(state.inference_source)
  end

  test "a live actor refuses an edited agent model before a turn exists", ctx do
    conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent)
    {pid, _ref, :alive} = start_server(conv)
    Repo.update!(Ecto.Changeset.change(ctx.agent, model: "openai/gpt-5.1"))

    assert {:error, :inference_source_changed} =
             GenServer.call(pid, {:send_prompt, "changed model", []})

    assert Conversations._unsafe_list_turns(conv.id) == []
  end

  test "stale source refusal leaves a ready shared machine and its other conversation intact",
       ctx do
    {:ok, source, _} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, ctx.agent.runtime,
        credential_set_id: ctx.selected.id
      )

    sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

    stale =
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: sandbox,
        inference_source: Source.dump(source)
      )

    healthy =
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: sandbox,
        status: "idle"
      )

    {:ok, _} =
      InferenceCredentials.put_credential_in(
        ctx.selected,
        ctx.dek,
        :openai_api_key,
        "replacement"
      )

    reject(Fountain.Conversations.Provisioning, :prepare_runtime_sprite, 5)
    {_pid, _ref, :stopped} = start_server(stale)
    assert Repo.reload!(stale).status == "failed"
    assert Repo.reload!(sandbox).status == "ready"
    assert Repo.reload!(healthy).status == "idle"
  end

  test "credential replacement during setup is refused before runtime auth preparation", ctx do
    env = insert_env(user_id: ctx.user.id)
    agent = Repo.update!(Ecto.Changeset.change(ctx.agent, environment_id: env.id))
    conv = insert_conversation(user_id: ctx.user.id, agent: agent)

    expect(Fountain.Conversations.Provisioning, :install_packages, fn _handle,
                                                                      _env,
                                                                      _pairs,
                                                                      _conv ->
      {:ok, _} =
        InferenceCredentials.put_credential_in(
          ctx.selected,
          ctx.dek,
          :openai_api_key,
          "replacement"
        )

      :ok
    end)

    reject(Fountain.Conversations.Provisioning, :prepare_runtime_sprite, 5)
    {_pid, _ref, :stopped} = start_server(conv)
    assert Repo.reload!(conv).status == "failed"
  end

  test "failed legacy env cleanup prevents runtime auth preparation on wake", ctx do
    sandbox = insert_sandbox(user_id: ctx.user.id, status: "pending")
    conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: sandbox)

    {:ok, source, _} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, ctx.agent.runtime,
        credential_set_id: ctx.selected.id
      )

    assert :ok = Fountain.Conversations.InferenceBinding.reserve(conv, source)
    Repo.update!(Ecto.Changeset.change(sandbox, status: "ready"))

    stub(Fountain.Conversations.Provisioning, :write_env_file, fn _handle, _pairs ->
      {:error, :cleanup_failed}
    end)

    reject(Fountain.Conversations.Provisioning, :prepare_runtime_sprite, 5)
    {_pid, _ref, :stopped} = start_server(conv)
    assert Repo.reload!(sandbox).status == "ready"
  end
end
