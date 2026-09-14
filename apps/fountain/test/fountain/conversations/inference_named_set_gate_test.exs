defmodule Fountain.Conversations.InferenceNamedSetGateTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Conversations, Credits, Crypto, InferenceCredentials, PlatformInference}
  alias Fountain.InferenceCredentials.Source

  setup do
    settings = [platform_anthropic_api_key: "sk-platform", platform_inference_daily_cents: 10]
    previous = Map.new(settings, fn {key, _} -> {key, Application.get_env(:fountain, key)} end)
    Enum.each(settings, fn {key, value} -> Application.put_env(:fountain, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, spawn(fn -> :ok end)} end)
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

    {:ok, _} =
      Credits.debit(user.id, 10, "burn_inference",
        idempotency_key: "named-set-gate:#{Ecto.UUID.generate()}",
        actor: "system:test"
      )

    %{user: user, default: default, selected: selected, agent: agent}
  end

  for door <- [:fresh, :attach] do
    test "#{door} admission uses the agent's named key after the platform ceiling is exhausted",
         ctx do
      refute InferenceCredentials.status_for_set(ctx.default).anthropic_api_key

      # The account default holds nothing, so a launch naming no set would
      # run on the platform key, and the ceiling is spent.
      assert {:ok, %Source{scope: :platform} = on_platform, _} =
               InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, ctx.agent.runtime, [])

      assert {:error, :platform_inference_unavailable} =
               PlatformInference.gate_source(on_platform)

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

      assert {:ok, conv} = Conversations.start_conversation(attrs)
      assert conv.inference_source["origin"] == "own"
      assert conv.inference_source["set_id"] == ctx.selected.id
      assert conv.inference_source["revision"] == ctx.selected.revision
      assert conv.inference_source["kind"] == "anthropic_api_key"
    end
  end
end
