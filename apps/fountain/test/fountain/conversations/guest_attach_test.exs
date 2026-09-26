defmodule Fountain.Conversations.GuestAttachTest do
  # A conversation of another agent attached to a home by `sandbox_id` (ADR
  # 0023, amended 2026-09-26, #2515): the attach door admits a guest whose
  # runtime keeps its files apart from every other agent's on the machine,
  # on the same environment and vault, and nothing else.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Conversations, Crypto, InferenceCredentials}
  alias Fountain.Conversations.{CotenantSecrets, Launch, Redaction}
  alias Fountain.Machines.Binding

  @claude_key "sk-ant-guest-attach-2515"
  @codex_key "sk-proj-guest-attach-2515"

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    claude_set = set_with(user, dek, "Claude", :anthropic_api_key, @claude_key)
    codex_set = set_with(user, dek, "Codex", :openai_api_key, @codex_key)

    %{user: user, env: env, claude_set: claude_set, codex_set: codex_set}
  end

  defp set_with(user, dek, name, kind, value) do
    {:ok, set} = InferenceCredentials.create_set(user.id, name)
    {:ok, set} = InferenceCredentials.put_credential_in(set, dek, kind, value)
    set
  end

  defp agent_of(ctx, runtime, overrides \\ [])

  defp agent_of(ctx, "codex", overrides) do
    insert_agent(
      [
        user_id: ctx.user.id,
        runtime: "codex",
        model: "openai/gpt-5",
        environment_id: ctx.env.id,
        inference_credential_id: ctx.codex_set.id
      ] ++ overrides
    )
  end

  defp agent_of(ctx, "claude", overrides) do
    insert_agent(
      [
        user_id: ctx.user.id,
        runtime: "claude",
        environment_id: ctx.env.id,
        inference_credential_id: ctx.claude_set.id
      ] ++ overrides
    )
  end

  defp agent_of(ctx, "acp", overrides) do
    insert_agent(
      [
        user_id: ctx.user.id,
        runtime: "acp",
        runtime_command: "my-agent acp",
        environment_id: ctx.env.id
      ] ++ overrides
    )
  end

  defp agent_of(ctx, runtime, overrides),
    do:
      insert_agent(
        [user_id: ctx.user.id, runtime: runtime, environment_id: ctx.env.id] ++ overrides
      )

  # A home made the way a launch makes one today: `sandbox_mode=persistent`,
  # reserved by `Provision.reserve/1` (so a claude home carries the Codex
  # stamp, #2516), then built.
  defp launched_home(ctx, agent) do
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    {:ok, conv} =
      Launch.start_conversation(%{
        "agent_id" => agent.id,
        "user_id" => ctx.user.id,
        "sandbox_mode" => "persistent"
      })

    home = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, home} = update_sandbox(home, %{status: "ready"})
    {home, conv}
  end

  # A home as a row, for the cases the reservation does not decide.
  defp home_row(ctx, agent, overrides \\ %{}) do
    home =
      insert_sandbox(
        Map.merge(
          %{
            user_id: ctx.user.id,
            agent_id: agent.id,
            environment_id: ctx.env.id,
            mode: "persistent",
            runtime: agent.runtime,
            status: "ready",
            provider: "sprites"
          },
          overrides
        )
      )

    host = insert_conversation(user_id: ctx.user.id, agent: agent, sandbox: home, status: "idle")
    {home, host}
  end

  defp attach(ctx, agent, sandbox, extra \\ %{}) do
    Launch.start_conversation(
      Map.merge(
        %{"agent_id" => agent.id, "user_id" => ctx.user.id, "sandbox_id" => sandbox.id},
        extra
      )
    )
  end

  describe "admitted" do
    test "a codex guest on a claude home created now, and its Codex bind", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, _host} = launched_home(ctx, host_agent)
      assert home.codex_peer_homes

      assert {:ok, guest} = attach(ctx, guest_agent, home)
      assert guest.sandbox_id == home.id
      assert guest.agent_id == guest_agent.id
      assert guest.runtime == "codex"

      # The bind was made at the attach, under the machine's lock, and recorded.
      home = Repo.reload!(home)
      assert home.codex_inference_source

      # The home stays its host's.
      assert home.agent_id == host_agent.id
      assert home.runtime == "claude"

      # A second conversation of the same guest agent is not another agent.
      assert {:ok, _} = attach(ctx, guest_agent, home)
    end

    test "a claude guest on a codex home", ctx do
      host_agent = agent_of(ctx, "codex")
      guest_agent = agent_of(ctx, "claude")
      {home, _host} = home_row(ctx, host_agent)

      assert {:ok, guest} = attach(ctx, guest_agent, home)
      assert guest.runtime == "claude"
      home = Repo.reload!(home)
      assert home.agent_id == host_agent.id
      assert home.runtime == "codex"
    end

    test "each side registers the other's inference credential once attached", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, host} = launched_home(ctx, host_agent)
      assert {:ok, guest} = attach(ctx, guest_agent, home)

      on_exit(fn ->
        Redaction.delete(host.id)
        Redaction.delete(guest.id)
      end)

      assert CotenantSecrets.register(host.id, home.id) == :mixed
      assert CotenantSecrets.register(guest.id, home.id) == :mixed
      assert @codex_key in Redaction.lookup(host.id)
      assert @claude_key in Redaction.lookup(guest.id)
    end

    test "capacity stays per runtime: a busy host does not hold a guest's first turn", ctx do
      # opencode runs one turn at a time; claude's files are elsewhere.
      host_agent = agent_of(ctx, "opencode")
      guest_agent = agent_of(ctx, "claude")
      {home, host} = home_row(ctx, host_agent)

      insert_turn(host, %{
        status: "running",
        prompt: "busy",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      stub(Fountain.Conversations.ConversationServer, :send_prompt, fn _id, _p, _i, _o -> :ok end)

      assert {:ok, _} = attach(ctx, guest_agent, home, %{"prompt" => "hello"})

      # The host's own runtime is still at capacity.
      assert {:error, :sandbox_at_capacity} =
               attach(ctx, host_agent, home, %{"prompt" => "hello"})
    end
  end

  describe "refused" do
    test "a codex guest on a claude home from before the stamp", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, _host} = home_row(ctx, host_agent)
      refute home.codex_peer_homes

      # The documented limitation: its `~/.codex/auth.json` may predate the
      # record, so the bind refuses until the home is reset.
      assert {:error, :codex_inference_conflict} = attach(ctx, guest_agent, home)
      assert [_host] = Conversations._unsafe_list_cotenant_ids(home.id, Ecto.UUID.generate())
    end

    test "two agents of one runtime", ctx do
      host_agent = agent_of(ctx, "claude")
      {home, _host} = home_row(ctx, host_agent)

      assert {:error, :sandbox_identity_mismatch} =
               attach(ctx, agent_of(ctx, "claude"), home)
    end

    test "an acp guest on a claude home: its skills root is claude's", ctx do
      {home, _host} = home_row(ctx, agent_of(ctx, "claude"))
      assert {:error, :sandbox_identity_mismatch} = attach(ctx, agent_of(ctx, "acp"), home)
    end

    test "any guest on an acp home: the command's files are not known", ctx do
      {home, _host} = home_row(ctx, agent_of(ctx, "acp"))
      assert {:error, :sandbox_identity_mismatch} = attach(ctx, agent_of(ctx, "codex"), home)
    end

    test "a different environment or vault", ctx do
      host_agent = agent_of(ctx, "claude")
      {home, _host} = home_row(ctx, host_agent)
      other_env = insert_env(user_id: ctx.user.id)
      vault = insert_vault(user_id: ctx.user.id)

      assert {:error, :sandbox_identity_mismatch} =
               attach(ctx, agent_of(ctx, "codex", environment_id: other_env.id), home)

      assert {:error, :sandbox_identity_mismatch} =
               attach(ctx, agent_of(ctx, "codex"), home, %{"environment_id" => other_env.id})

      assert {:error, :sandbox_identity_mismatch} =
               attach(ctx, agent_of(ctx, "codex"), home, %{"vault_id" => vault.id})
    end

    test "a machine with no recorded runtime, or not a home", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "opencode")

      {legacy, _} = home_row(ctx, host_agent)

      legacy =
        legacy |> Ecto.Changeset.change(runtime: nil) |> Repo.update!()

      assert {:error, :sandbox_identity_mismatch} = attach(ctx, guest_agent, legacy)

      {ephemeral, _} = home_row(ctx, host_agent, %{mode: "ephemeral"})
      assert {:error, :sandbox_identity_mismatch} = attach(ctx, guest_agent, ephemeral)
    end

    test "a retired conversation of another agent still holds its runtime's files", ctx do
      host_agent = agent_of(ctx, "codex")
      {home, _host} = home_row(ctx, host_agent)
      earlier = agent_of(ctx, "claude")

      insert_conversation(
        user_id: ctx.user.id,
        agent: earlier,
        sandbox: home,
        status: "terminated"
      )

      assert {:error, :sandbox_identity_mismatch} = attach(ctx, agent_of(ctx, "claude"), home)

      # The agent that left them is not another agent to itself.
      assert {:ok, _} = attach(ctx, earlier, home)
    end

    test "a conversation whose agent was deleted counts as another agent's", ctx do
      host_agent = agent_of(ctx, "codex")
      {home, _host} = home_row(ctx, host_agent)
      gone = agent_of(ctx, "claude")
      conv = insert_conversation(user_id: ctx.user.id, agent: gone, sandbox: home)
      conv |> Ecto.Changeset.change(agent_id: nil) |> Repo.update!()

      assert {:error, :sandbox_identity_mismatch} = attach(ctx, agent_of(ctx, "claude"), home)
    end

    test "the home's own agent on a runtime it has since changed", ctx do
      host_agent = agent_of(ctx, "claude")
      {home, _host} = home_row(ctx, host_agent)
      moved = host_agent |> Ecto.Changeset.change(runtime: "codex") |> Repo.update!()

      assert {:error, :sandbox_runtime_mismatch} =
               Binding.attachable(home, moved, nil, ctx.env.id)
    end
  end
end
