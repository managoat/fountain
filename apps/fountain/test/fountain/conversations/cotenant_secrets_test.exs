defmodule Fountain.Conversations.CotenantSecretsTest do
  # #2513: a `claude` and a `codex` conversation on one machine read each
  # other's inference credential off the shared disk, so each registers the
  # other's for redaction. The mixed machine is built directly, two bound
  # conversations of different runtimes on one `sandboxes` row; the attach
  # that makes one (#2515) is `guest_attach_test.exs`'s.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{CotenantSecrets, InferenceResolution, Redaction, TurnMachine}
  alias Fountain.{Crypto, InferenceCredentials}
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.InferenceCredentials.Source

  import Ecto.Query

  @claude_key "sk-ant-claude-cotenant-2513"
  @codex_key "sk-proj-codex-cotenant-2513"

  setup do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    claude_set = set_with(user, dek, "Claude", :anthropic_api_key, @claude_key)
    codex_set = set_with(user, dek, "Codex", :openai_api_key, @codex_key)
    claude_agent = insert_agent(user_id: user.id, runtime: "claude")
    codex_agent = insert_agent(user_id: user.id, runtime: "codex")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    %{
      user: user,
      dek: dek,
      sandbox: sandbox,
      claude_set: claude_set,
      codex_set: codex_set,
      claude_agent: set_agent(claude_agent, claude_set),
      codex_agent: set_agent(codex_agent, codex_set)
    }
  end

  defp set_with(user, dek, name, kind, value) do
    {:ok, set} = InferenceCredentials.create_set(user.id, name)
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, kind, value)
    set
  end

  defp set_agent(agent, set) do
    agent |> Ecto.Changeset.change(inference_credential_id: set.id) |> Repo.update!()
  end

  # A conversation as admission leaves it: bound to the machine, with the
  # source its selection resolved stored on the row.
  defp bound(ctx, agent, overrides \\ %{}) do
    {:ok, source, _creds} = InferenceResolution.select(ctx.user.id, agent, [])

    conv =
      insert_conversation(
        Map.merge(
          %{
            user_id: ctx.user.id,
            agent: agent,
            sandbox: ctx.sandbox,
            status: "idle",
            inference_source: Source.dump(source)
          },
          overrides
        )
      )

    on_exit(fn -> Redaction.delete(conv.id) end)
    conv
  end

  # What a registration could conceivably write: the audit trail, the
  # conversations' stored sources and bindings, the machine's Codex binding.
  defp rows(ctx, convs) do
    ids = Enum.map(convs, & &1.id)

    {Repo.aggregate(Fountain.Audit.Event, :count),
     Repo.all(from c in Conversation, where: c.id in ^ids, order_by: c.id),
     Repo.get!(Sandbox, ctx.sandbox.id)}
  end

  describe "a mixed-runtime machine" do
    test "each conversation registers the other's inference credential", ctx do
      claude = bound(ctx, ctx.claude_agent)
      codex = bound(ctx, ctx.codex_agent)

      assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
      assert CotenantSecrets.register(codex.id, ctx.sandbox.id) == :mixed

      assert @codex_key in Redaction.lookup(claude.id)
      assert @claude_key in Redaction.lookup(codex.id)
    end

    test "the claude conversation's output of codex's auth.json is scrubbed", ctx do
      claude = bound(ctx, ctx.claude_agent)
      _codex = bound(ctx, ctx.codex_agent)

      CotenantSecrets.register(claude.id, ctx.sandbox.id)

      auth_json = ~s({"OPENAI_API_KEY": "#{@codex_key}"})
      redacted = Redaction.redact(claude.id, auth_json)

      refute redacted =~ @codex_key
      assert redacted =~ Redaction.placeholder()
    end

    test "registration adds and never forgets what the conversation had", ctx do
      claude = bound(ctx, ctx.claude_agent)
      _codex = bound(ctx, ctx.codex_agent)
      Redaction.put(claude.id, ["own-secret-value-2513"])

      CotenantSecrets.register(claude.id, ctx.sandbox.id)

      assert "own-secret-value-2513" in Redaction.lookup(claude.id)
      assert @codex_key in Redaction.lookup(claude.id)
    end

    test "a co-tenant whose source moved is re-read on the set it names", ctx do
      claude = bound(ctx, ctx.claude_agent)
      _codex = bound(ctx, ctx.codex_agent)

      # A new revision of the codex set: the stored source no longer
      # re-validates, and the value now in the set is registered anyway.
      {:ok, _} =
        InferenceCredentials.put_credential_in(
          ctx.codex_set,
          ctx.dek,
          :openai_api_key,
          "sk-proj-rotated-2513"
        )

      assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
      assert "sk-proj-rotated-2513" in Redaction.lookup(claude.id)
    end

    # Its `auth.json` is still on the disk: nothing deletes it when the
    # conversation ends, and the claude conversation that wakes afterwards
    # starts with an empty registry.
    test "a retired co-tenant of another runtime is still registered", ctx do
      claude = bound(ctx, ctx.claude_agent)
      _terminated = bound(ctx, ctx.codex_agent, %{status: "terminated"})
      _failed = bound(ctx, ctx.codex_agent, %{status: "failed"})

      assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
      assert @codex_key in Redaction.lookup(claude.id)
    end

    test "many conversations on one source resolve once", ctx do
      claude = bound(ctx, ctx.claude_agent)
      for _ <- 1..4, do: bound(ctx, ctx.codex_agent, %{status: "terminated"})
      _live = bound(ctx, ctx.codex_agent)

      test = self()

      Mimic.stub(InferenceResolution, :revalidate, fn conv, agent, opts ->
        send(test, :resolved)
        Mimic.call_original(InferenceResolution, :revalidate, [conv, agent, opts])
      end)

      assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
      assert_received :resolved
      refute_received :resolved
      assert @codex_key in Redaction.lookup(claude.id)
    end

    test "registration writes nothing", ctx do
      claude = bound(ctx, ctx.claude_agent)
      codex = bound(ctx, ctx.codex_agent)
      snapshot = fn -> rows(ctx, [claude, codex]) end
      before = snapshot.()

      assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
      assert CotenantSecrets.register(codex.id, ctx.sandbox.id) == :mixed

      assert snapshot.() == before
    end

    test "a co-tenant that cannot be resolved registers nothing and does not raise", ctx do
      claude = bound(ctx, ctx.claude_agent)

      # A stored source naming a set that no longer exists.
      codex = bound(ctx, ctx.codex_agent)
      gone = Map.put(codex.inference_source, "set_id", Ecto.UUID.generate())
      codex |> Ecto.Changeset.change(inference_source: gone) |> Repo.update!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
        end)

      assert log =~ "inference_credential_not_found"
      assert Redaction.lookup(claude.id) == []
    end

    test "a co-tenant whose agent, environment and vault are gone does not raise", ctx do
      claude = bound(ctx, ctx.claude_agent)
      env = insert_env(user_id: ctx.user.id)
      vault = insert_vault(user_id: ctx.user.id)

      codex =
        bound(ctx, ctx.codex_agent, %{environment_id: env.id, vault_id: vault.id})

      Repo.delete!(env)
      Repo.delete!(vault)
      # What deleting the agent leaves on a conversation that outlives it.
      Repo.update_all(from(c in Conversation, where: c.id == ^codex.id), set: [agent_id: nil])

      assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :mixed
      # The stored set still names the key, so it is registered anyway.
      assert @codex_key in Redaction.lookup(claude.id)
    end
  end

  describe "a single-runtime machine" do
    test "a shared machine's registry is left exactly as it was", ctx do
      a = bound(ctx, ctx.claude_agent)
      b = bound(ctx, ctx.claude_agent)
      Redaction.put(a.id, ["own-secret-value-2513"])
      before = {Redaction.lookup(a.id), Redaction.patterns(a.id)}

      assert CotenantSecrets.register(a.id, ctx.sandbox.id) == :single
      assert CotenantSecrets.register(b.id, ctx.sandbox.id) == :single

      assert {Redaction.lookup(a.id), Redaction.patterns(a.id)} == before
      assert Redaction.lookup(b.id) == []
    end

    test "retired conversations of the same runtime keep it single and unchanged", ctx do
      a = bound(ctx, ctx.claude_agent)
      _retired = bound(ctx, ctx.claude_agent, %{status: "terminated"})
      _failed = bound(ctx, ctx.claude_agent, %{status: "failed"})
      Redaction.put(a.id, ["own-secret-value-2513"])
      before = {Redaction.lookup(a.id), Redaction.patterns(a.id)}

      Mimic.reject(&InferenceResolution.revalidate/3)

      assert CotenantSecrets.register(a.id, ctx.sandbox.id) == :single
      assert {Redaction.lookup(a.id), Redaction.patterns(a.id)} == before
    end

    test "a machine with no sandbox id is single", ctx do
      a = bound(ctx, ctx.claude_agent)
      assert CotenantSecrets.register(a.id, nil) == :single
    end

    test "an assembled env announces nothing", ctx do
      a = bound(ctx, ctx.claude_agent)
      _b = bound(ctx, ctx.claude_agent)
      env = [{"K", "v"}]

      assert CotenantSecrets.assembled(env, %{conversation_id: a.id, sandbox_id: ctx.sandbox.id}) ==
               env

      refute_receive {:cotenant_arrived, _, _}, 50
      assert Redaction.lookup(a.id) == []
    end
  end

  test "another owner's conversation on the row is not a co-tenant", ctx do
    claude = bound(ctx, ctx.claude_agent)
    other = insert_verified_user()
    other_agent = insert_agent(user_id: other.id, runtime: "codex")

    insert_conversation(
      user_id: other.id,
      agent: other_agent,
      sandbox: ctx.sandbox,
      status: "idle"
    )

    assert CotenantSecrets.register(claude.id, ctx.sandbox.id) == :single
  end

  describe "the machine's topic" do
    test "an env assembled on a mixed machine announces it, once per subscriber", ctx do
      claude = bound(ctx, ctx.claude_agent)
      codex = bound(ctx, ctx.codex_agent)
      state = %{conversation_id: codex.id, sandbox_id: ctx.sandbox.id}

      # Twice, as a server that wakes twice does: still one subscription.
      CotenantSecrets.assembled([], state)
      CotenantSecrets.assembled([], state)

      sandbox_id = ctx.sandbox.id
      codex_id = codex.id
      assert_receive {:cotenant_arrived, ^sandbox_id, ^codex_id}
      assert_receive {:cotenant_arrived, ^sandbox_id, ^codex_id}
      refute_receive {:cotenant_arrived, _, _}, 50

      assert @claude_key in Redaction.lookup(codex.id)
      refute @codex_key in Redaction.lookup(claude.id)
    end

    test "an arrival registers for the server that hears it", ctx do
      claude = bound(ctx, ctx.claude_agent)
      codex = bound(ctx, ctx.codex_agent)
      state = %{conversation_id: claude.id, sandbox_id: ctx.sandbox.id}

      assert CotenantSecrets.arrived({:cotenant_arrived, ctx.sandbox.id, codex.id}, state) ==
               state

      assert @codex_key in Redaction.lookup(claude.id)
    end

    test "its own arrival, or another machine's, registers nothing", ctx do
      claude = bound(ctx, ctx.claude_agent)
      codex = bound(ctx, ctx.codex_agent)
      state = %{conversation_id: claude.id, sandbox_id: ctx.sandbox.id}

      CotenantSecrets.arrived({:cotenant_arrived, ctx.sandbox.id, claude.id}, state)
      CotenantSecrets.arrived({:cotenant_arrived, Ecto.UUID.generate(), codex.id}, state)

      assert Redaction.lookup(claude.id) == []
    end
  end

  test "turn admission on a mixed machine registers the co-tenant's credential", ctx do
    claude = bound(ctx, ctx.claude_agent)
    _codex = bound(ctx, ctx.codex_agent)
    source = Source.load(claude.inference_source)

    assert {:ok, _conv, _turn} =
             TurnMachine.open(claude.id, ctx.sandbox.id, "hi", ctx.claude_agent, nil, source)

    assert @codex_key in Redaction.lookup(claude.id)
  end
end
