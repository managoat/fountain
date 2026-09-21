defmodule Fountain.Conversations.ChatGPTGrantAdmissionTest do
  @moduledoc """
  What admission does with a credential set that names a ChatGPT
  subscription (ADR 0060 stage 2), through the real launch doors.

  Two refusals, and neither leaves a row behind:

    * an unusable grant is `{:chatgpt_grant_unusable, _}`, naming it, and the
      launch does not land on the set's key or on platform inference;
    * a usable one is `:chatgpt_grant_transport_unavailable`. Selection is
      built and the transport that carries a user's grant into a sandbox is
      stage 3, which deletes that guard and this half of the file with it.

  `async: false`: the broker is application env and the platform grant is
  connected.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.Conversations.{CodexChatGPT, Conversation, InferenceBinding, Launch, Sandbox}
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source

  setup do
    stub_server_start(fn _sup, _spec -> {:ok, spawn(fn -> :ok end)} end)

    restore =
      for key <- [:broker_listen_port, :broker_proxy_url, :platform_openai_api_key],
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
    Application.put_env(:fountain, :platform_openai_api_key, "sk-platform")
    connect!()

    user = insert_active_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    grant = user_grant!(user.id, %{name: "Work"})
    {:ok, set} = InferenceCredentials.create_set(user.id, "Subscription")
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, :openai_api_key, "sk-own")
    {:ok, set} = InferenceCredentials.set_grant(set, grant.id)
    agent = insert_agent(user_id: user.id, runtime: "codex", inference_credential_id: set.id)

    %{user: user, grant: grant, set: set, agent: agent}
  end

  defp rows(user) do
    {Repo.aggregate(from(c in Conversation, where: c.user_id == ^user.id), :count),
     Repo.aggregate(from(s in Sandbox, where: s.user_id == ^user.id), :count)}
  end

  defp launch(ctx, extra) do
    Launch.start_conversation(
      Map.merge(%{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id}, extra)
    )
  end

  for door <- [:fresh, :attach] do
    test "#{door}: an unusable named grant refuses the launch by name, with no fallback", ctx do
      :ok = ChatGPTAccounts.disconnect_for_user(ctx.grant.id, ctx.user.id)

      extra =
        case unquote(door) do
          :fresh ->
            %{"sandbox_mode" => "ephemeral"}

          :attach ->
            sandbox =
              insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

            %{"sandbox_id" => sandbox.id}
        end

      before = rows(ctx.user)

      assert {:error, {:chatgpt_grant_unusable, detail}} = launch(ctx, extra)
      assert %{grant_id: id, name: "Work", reason: :disconnected} = detail
      assert id == ctx.grant.id
      assert rows(ctx.user) == before
    end

    test "#{door}: a usable named grant is refused until its transport exists", ctx do
      extra =
        case unquote(door) do
          :fresh ->
            %{"sandbox_mode" => "ephemeral"}

          :attach ->
            sandbox =
              insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

            %{"sandbox_id" => sandbox.id}
        end

      before = rows(ctx.user)

      assert {:error, :chatgpt_grant_transport_unavailable} = launch(ctx, extra)
      assert rows(ctx.user) == before
    end
  end

  test "a launch that overrides the set with one naming no grant is not affected", ctx do
    {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
    {:ok, plain} = InferenceCredentials.create_set(ctx.user.id, "Key only")
    {:ok, plain} = InferenceCredentials.put_credential_in(plain, dek, :openai_api_key, "sk-key")

    assert {:ok, conv} =
             launch(ctx, %{
               "sandbox_mode" => "ephemeral",
               "inference_credential_id" => plain.id
             })

    assert %{"scope" => "credential", "kind" => "openai_api_key"} = conv.inference_source
    refute Map.has_key?(conv.inference_source, "grant_id")
  end

  test "reserve/2 refuses a grant source too, so no conversation is ever bound to one", ctx do
    {:ok, %Source{scope: :grant} = source, _} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, "codex",
        credential_set_id: ctx.set.id
      )

    sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

    conv =
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox_id: sandbox.id,
        runtime: "codex"
      )

    assert {:error, :chatgpt_grant_transport_unavailable} = InferenceBinding.reserve(conv, source)
    assert is_nil(Repo.reload!(conv).inference_source)
    assert is_nil(Repo.reload!(sandbox).codex_inference_source)
  end

  # Binding is not the only way a source reaches a turn: a wake that reuses a
  # live machine starts a server on whatever the row holds. Nothing in lib/
  # persists a grant source without `reserve/2` today, so the row is written
  # here by hand, as a stage-3 or stage-5 path that forgot to bind would.
  test "a grant source persisted some other way is refused at the turn, by both doors", ctx do
    {:ok, %Source{scope: :grant} = source, _} =
      InferenceCredentials.resolve(ctx.user.id, ctx.agent.model, "codex",
        credential_set_id: ctx.set.id
      )

    sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

    conv =
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox_id: sandbox.id,
        runtime: "codex"
      )

    conv
    |> Ecto.Changeset.change(inference_source: Source.dump(source))
    |> Repo.update!()

    # The source itself still validates: only the transport refuses it.
    assert :ok = InferenceCredentials.validate_source(ctx.user.id, source)

    assert {:error, :chatgpt_grant_transport_unavailable} =
             Fountain.Conversations.TurnMachine.gate(ctx.user.id, source)

    assert {:error, :chatgpt_grant_transport_unavailable} =
             Fountain.Conversations._unsafe_create_turn_on_sandbox(
               %{
                 conversation_id: conv.id,
                 turn_number: 1,
                 prompt: "hi",
                 status: "running",
                 started_at: DateTime.utc_now() |> DateTime.truncate(:second)
               },
               sandbox.id
             )

    assert Fountain.Conversations._unsafe_list_turns(conv.id) == []
  end

  test "transport_ready/1 refuses only a grant source" do
    assert {:error, :chatgpt_grant_transport_unavailable} =
             CodexChatGPT.transport_ready(Source.grant())

    for source <- [
          Source.credential(),
          Source.tenant_secret(),
          Source.platform(),
          Source.none(),
          Source.missing()
        ] do
      assert :ok = CodexChatGPT.transport_ready(source)
    end

    # A conversation admitted before sources were stored.
    assert :ok = CodexChatGPT.transport_ready(nil)
  end
end
