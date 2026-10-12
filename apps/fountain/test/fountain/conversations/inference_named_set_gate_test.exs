defmodule Fountain.Conversations.InferenceNamedSetGateTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Conversations.Launch

  setup do
    settings = [platform_anthropic_api_key: "sk-platform"]
    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:fountain, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:fountain, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    stub_server_start(fn _, _ -> {:ok, spawn(fn -> :ok end)} end)
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, default} = InferenceCredentials.create_set(user.id, "Default without inference")
    {:ok, selected} = InferenceCredentials.create_set(user.id, "Agent inference")

    {:ok, selected} =
      InferenceCredentials.put_credential_in(selected, dek, :anthropic_api_key, "sk-selected")

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        model: "anthropic/claude-opus-5",
        inference_credential_id: selected.id
      )

    %{user: user, default: default, selected: selected, agent: agent}
  end

  for door <- [:fresh, :attach] do
    test "#{door} admission uses the agent's named key over the platform key", ctx do
      refute InferenceCredentials.status_for_set(ctx.default).anthropic_api_key

      # The account default holds nothing, so a launch naming no set would
      # run on the platform key.
      assert {:ok, %Source{scope: :platform}, _} =
               InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, ctx.agent.runtime, [])

      attrs = %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id}

      attrs =
        case unquote(door) do
          :fresh ->
            Map.put(attrs, "sandbox_mode", "ephemeral")

          :attach ->
            sandbox =
              insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

            Map.put(attrs, "sandbox_id", sandbox.id)
        end

      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.inference_source["origin"] == "own"
      assert conv.inference_source["set_id"] == ctx.selected.id
      assert conv.inference_source["revision"] == ctx.selected.revision
      assert conv.inference_source["kind"] == "anthropic_api_key"
    end
  end
end
