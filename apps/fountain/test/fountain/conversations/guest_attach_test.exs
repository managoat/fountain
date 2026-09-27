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

  # A full-scope caller's attach, as `ConversationController.create/2` makes
  # it for an owner's own key (#2525). `attach_as/5` names the options.
  defp attach(ctx, agent, sandbox, extra \\ %{}),
    do: attach_as(ctx, agent, sandbox, extra, guest_ok: true)

  defp attach_as(ctx, agent, sandbox, extra, opts) do
    Launch.start_conversation(
      Map.merge(
        %{"agent_id" => agent.id, "user_id" => ctx.user.id, "sandbox_id" => sandbox.id},
        extra
      ),
      opts
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

    test "a guest is pinned to the environment it was admitted on", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, host} = launched_home(ctx, host_agent)

      assert {:ok, guest} = attach(ctx, guest_agent, home)
      assert guest.environment_id == ctx.env.id
      # A conversation of the home's own agent still follows its agent.
      assert {:ok, same} = attach(ctx, host_agent, home)
      assert is_nil(same.environment_id)
      assert is_nil(host.environment_id)

      # The guest's agent moves to another environment: the guest does not,
      # so it neither leaves the home nor writes the other environment to it.
      other_env = insert_env(user_id: ctx.user.id)

      {:ok, guest_agent} =
        Fountain.Agents.update_agent(guest_agent, %{"environment_id" => other_env.id})

      guest = Conversations._unsafe_get_conversation!(guest.id)
      assert guest.environment_id == ctx.env.id
      refute Binding.guest_moved?(Repo.reload!(home), guest, guest_agent)
      assert Repo.reload!(home).status == "ready"
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
      # Claude and codex both run turns side by side, and only they pair
      # (#2525), so the host's runtime is held to one turn here to show the
      # count is per runtime.
      stub(Fountain.RuntimeDispatch, :concurrency, fn
        "codex" -> 1
        _runtime -> :unbounded
      end)

      host_agent = agent_of(ctx, "codex")
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

  describe "who may make the pairing (#2525)" do
    test "a caller that is not full scope may not attach a guest", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, _host} = launched_home(ctx, host_agent)

      # No option at all is the default a new caller gets, and a sandbox
      # token's request says `false`.
      for opts <- [[], [guest_ok: false], [sandbox_key_id: Ecto.UUID.generate()]] do
        assert {:error, :guest_attach_requires_full_scope} =
                 attach_as(ctx, guest_agent, home, %{}, opts)
      end

      assert [_host] = Conversations._unsafe_list_cotenant_ids(home.id, Ecto.UUID.generate())
      assert Repo.reload!(home).codex_inference_source == nil

      # The home's own agent is no guest: unchanged for any caller.
      assert {:ok, _} = attach_as(ctx, host_agent, home, %{}, [])
    end

    test "a refusal of the pair outranks the caller's scope", ctx do
      {home, _host} = home_row(ctx, agent_of(ctx, "claude"))

      assert {:error, :sandbox_identity_mismatch} =
               attach_as(ctx, agent_of(ctx, "claude"), home, %{}, [])

      assert {:error, :sandbox_identity_mismatch} =
               attach_as(ctx, agent_of(ctx, "opencode"), home, %{}, [])
    end

    test "a second conversation of an admitted guest is still a new pairing", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, _host} = launched_home(ctx, host_agent)
      assert {:ok, _guest} = attach(ctx, guest_agent, home)

      assert {:error, :guest_attach_requires_full_scope} =
               attach_as(ctx, guest_agent, home, %{}, [])
    end

    test "an ended predecessor of the same agent on the same machine is a successor", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, host} = launched_home(ctx, host_agent)
      assert {:ok, guest} = attach(ctx, guest_agent, home)

      # Live, it is not: a successor beside it would be a second guest.
      assert {:error, :guest_attach_requires_full_scope} =
               Binding.attachable(Repo.reload!(home), guest_agent, nil, ctx.env.id, :db,
                 successor_of: guest.id
               )

      # Released first, as a team rotation does.
      {:ok, _} = Conversations.update_conversation(guest, %{status: "terminated"})

      assert :ok =
               Binding.attachable(Repo.reload!(home), guest_agent, nil, ctx.env.id, :db,
                 successor_of: guest.id
               )

      # Not a conversation of another agent, of another machine, or no id.
      {:ok, _} = Conversations.update_conversation(host, %{status: "terminated"})
      {_other_home, other_guest} = home_row(ctx, guest_agent, %{status: "ready"})
      {:ok, _} = Conversations.update_conversation(other_guest, %{status: "terminated"})

      for id <- [host.id, other_guest.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :guest_attach_requires_full_scope} =
                 Binding.attachable(Repo.reload!(home), guest_agent, nil, ctx.env.id, :db,
                   successor_of: id
                 )
      end
    end

    # The review probe (#2525): a `fresh` channel rotation only unbinds its
    # predecessor, which keeps running, so letting it through would let a
    # sandbox token that knows a guest's channel stack live guests.
    test "a channel rotation of a guest needs a full-scope caller", ctx do
      host_agent = agent_of(ctx, "claude")
      guest_agent = agent_of(ctx, "codex")
      {home, _host} = launched_home(ctx, host_agent)
      channel = %{"channel_id" => "chan-2525", "environment_id" => ctx.env.id}
      assert {:ok, guest} = attach(ctx, guest_agent, home, channel)

      rotation =
        Map.merge(channel, %{
          "agent_id" => guest_agent.id,
          "user_id" => ctx.user.id,
          "sandbox_id" => home.id,
          "fresh" => true
        })

      for _ <- 1..3 do
        assert {:error, :guest_attach_requires_full_scope} =
                 Launch.start_or_resume_conversation(rotation, [])
      end

      # Nothing stacked, and the channel is still the guest's.
      assert [guest.id] ==
               Repo.all(
                 from c in Fountain.Conversations.Conversation,
                   where: c.sandbox_id == ^home.id and c.agent_id == ^guest_agent.id,
                   select: c.id
               )

      assert Conversations._unsafe_get_conversation!(guest.id).channel_id == "chan-2525"

      assert {:ok, fresh, :created} =
               Launch.start_or_resume_conversation(rotation, guest_ok: true)

      assert fresh.sandbox_id == home.id
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
      guest_agent = agent_of(ctx, "codex")

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

    test "any pair but claude and codex, though the directories are apart (#2525)", ctx do
      for {host, guest} <- [
            {"claude", "opencode"},
            {"claude", "gemini"},
            {"codex", "gemini"},
            {"codex", "opencode"},
            {"gemini", "opencode"},
            {"opencode", "claude"},
            {"gemini", "codex"}
          ] do
        {home, _host} = home_row(ctx, agent_of(ctx, host))

        assert {:error, :sandbox_identity_mismatch} = attach(ctx, agent_of(ctx, guest), home),
               "#{guest} on a #{host} home"
      end
    end

    test "claude and codex, once a third runtime has run on the machine", ctx do
      host_agent = agent_of(ctx, "codex")
      {home, _host} = home_row(ctx, host_agent)

      # A retired conversation of an opencode agent, from before the rule.
      insert_conversation(
        user_id: ctx.user.id,
        agent: agent_of(ctx, "opencode"),
        sandbox: home,
        status: "terminated"
      )

      assert {:error, :sandbox_identity_mismatch} = attach(ctx, agent_of(ctx, "claude"), home)
    end

    test "a second agent of a runtime already on the machine, by that rule alone", ctx do
      host_agent = agent_of(ctx, "claude")
      first = agent_of(ctx, "codex")
      {home, _host} = home_row(ctx, host_agent, %{codex_peer_homes: true})
      insert_conversation(user_id: ctx.user.id, agent: first, sandbox: home, status: "idle")

      # Every call gets roots of its own, so the directory rule finds no
      # overlap anywhere: only one-agent-per-runtime is left to refuse.
      stub(Managoat.Runtimes.Layout, :config_root, fn runtime ->
        "/unique/#{runtime}/#{System.unique_integer([:positive])}"
      end)

      stub(Fountain.RuntimeDispatch, :for_agent, fn _agent ->
        {:ok, __MODULE__.DistinctRoots}
      end)

      second = agent_of(ctx, "codex")

      assert {:error, :sandbox_identity_mismatch} =
               Binding.attachable(Repo.reload!(home), second, nil, ctx.env.id, :db,
                 guest_ok: true
               )

      # The stubs admit what they should: the first codex agent is no second.
      assert :ok =
               Binding.attachable(Repo.reload!(home), first, nil, ctx.env.id, :db, guest_ok: true)
    end

    test "the home's own agent on a runtime it has since changed", ctx do
      host_agent = agent_of(ctx, "claude")
      {home, _host} = home_row(ctx, host_agent)
      moved = host_agent |> Ecto.Changeset.change(runtime: "codex") |> Repo.update!()

      assert {:error, :sandbox_runtime_mismatch} =
               Binding.attachable(home, moved, nil, ctx.env.id)
    end
  end

  defmodule DistinctRoots do
    @moduledoc false
    def skills_root, do: "/unique/skills/#{System.unique_integer([:positive])}"
  end
end
