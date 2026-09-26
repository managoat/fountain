defmodule Fountain.Conversations.ConversationServerCotenantTest do
  # #2513 through a real server: a conversation on a mixed-runtime machine
  # registers its co-tenant's inference credential when it assembles its env,
  # and again when a co-tenant of another runtime announces itself on the
  # machine's topic. The mixed machine is built directly (#2515 has not
  # relaxed the attach rule yet).
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.{CotenantSecrets, InferenceResolution, Redaction}
  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.InferenceCredentials.Source

  @claude_key "sk-ant-claude-server-cotenant-2513"
  @codex_key "sk-proj-codex-server-cotenant-2513"

  setup do
    # The harness answers every tenant key with this one, so the sets are
    # written under it.
    stub_happy_sprite()
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    %{
      user: user,
      sandbox: sandbox,
      claude_agent: agent_on(user, dek, "claude", :anthropic_api_key, @claude_key),
      codex_agent: agent_on(user, dek, "codex", :openai_api_key, @codex_key)
    }
  end

  defp agent_on(user, dek, runtime, kind, value) do
    {:ok, set} = InferenceCredentials.create_set(user.id, runtime)
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, kind, value)

    insert_agent(user_id: user.id, runtime: runtime)
    |> Ecto.Changeset.change(inference_credential_id: set.id)
    |> Repo.update!()
  end

  defp bound(ctx, agent) do
    {:ok, source, _creds} = InferenceResolution.select(ctx.user.id, agent, [])

    insert_conversation(
      user_id: ctx.user.id,
      agent: agent,
      sandbox: ctx.sandbox,
      status: "idle",
      inference_source: Source.dump(source)
    )
  end

  # `FakeRuntime` exports no inference credential, so a server's own key is
  # not in its registry here (`SpriteEnv.exported_credentials/3`): whatever
  # the registry holds of these two keys came from `CotenantSecrets`.
  defp start(conv) do
    {pid, _ref, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "a wake on a mixed machine registers the co-tenant's credential", ctx do
    claude = bound(ctx, ctx.claude_agent)
    _codex = bound(ctx, ctx.codex_agent)

    start(claude)

    assert @codex_key in Redaction.lookup(claude.id)
  end

  test "a wake on a single-runtime machine registers only its own", ctx do
    a = bound(ctx, ctx.claude_agent)
    _b = bound(ctx, ctx.claude_agent)

    start(a)

    refute @codex_key in Redaction.lookup(a.id)
    refute @claude_key in Redaction.lookup(a.id)
  end

  test "a co-tenant of another runtime announced later is registered", ctx do
    claude = bound(ctx, ctx.claude_agent)
    pid = start(claude)
    refute @codex_key in Redaction.lookup(claude.id)

    codex = bound(ctx, ctx.codex_agent)
    :ok = CotenantSecrets.announce(ctx.sandbox.id, codex.id)
    # The announcement is handled in the server's own process; a call behind
    # it returns once it has been.
    _ = :sys.get_state(pid)

    assert @codex_key in Redaction.lookup(claude.id)
  end
end
