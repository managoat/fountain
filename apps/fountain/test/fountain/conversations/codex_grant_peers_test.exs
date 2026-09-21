defmodule Fountain.Conversations.CodexGrantPeersTest do
  # ADR 0060 stage 3's acceptance test, through two real ConversationServers:
  # two of one user's ChatGPT subscriptions, in one shared sandbox, at the same
  # time. One codex agent, one persistent home, two conversations whose
  # launches named two credential sets, each naming a different grant.
  #
  # What has to hold: neither is refused as `:codex_inference_conflict`; each
  # gets an `auth.json` of its own, in a `CODEX_HOME` of its own, naming its
  # own account and its own placeholder; neither home reaches the shared
  # `.env`; each gets a broker session pinned to its own grant; and the bearer
  # of neither is anywhere a conversation can reach: not in server state, not
  # in the `brokered` map, not in the session's rules, not in the redaction
  # registry and not in a log event.
  #
  # The broker's half of the same acceptance test (whose bearer the origin
  # really receives, rotation, disconnect) is
  # `broker/managed_grant_proxy_test.exs`, over a real tunnel.
  use Fountain.ConversationServerCase

  import Fountain.ChatGPTFixtures

  alias Fountain.Broker.Native.{Session, Sessions}
  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.Reserved
  alias Fountain.Conversations.Redaction
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Managoat.Broker.ProtectedCredential

  @protected %{
    protected: true,
    scheme: :https,
    host: "chatgpt.com",
    port: 443,
    method: "POST",
    target: "/backend-api/codex/responses"
  }

  setup do
    previous =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    # First, so the grants below are written under the key the servers read
    # with: the case stubs the tenant key to one fixed DEK.
    stub_happy_sprite()
    stub(Fountain.Broker, :preflight, fn -> :ok end)
    stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
    stub(Fountain.RuntimeDispatch, :install, fn _handle, "codex", _env -> :ok end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "codex", model: "openai/gpt-5.5-codex")

    # A persistent home first bound under stage 3.
    sandbox =
      insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
      |> Ecto.Changeset.change(codex_peer_homes: true)
      |> Repo.update!()

    peers =
      for name <- ["Personal", "Work"] do
        access = access_token(3_600, %{"subscription" => name})
        grant = user_grant!(user.id, %{name: name, access_token: access})
        {:ok, set} = InferenceCredentials.create_set(user.id, name <> " set")
        {:ok, set} = InferenceCredentials.set_grant(set, grant.id)

        conv =
          insert_conversation(
            user_id: user.id,
            agent: agent,
            sandbox: sandbox,
            runtime: "codex",
            status: "idle",
            inference_credential_id: set.id
          )

        %{name: name, grant: grant, access: access, conv: conv}
      end

    {:ok, user: user, sandbox: sandbox, peers: peers}
  end

  # Everything the sandbox is told, sent back to the test with the
  # conversation it was told for where that is knowable.
  defp record_sandbox do
    test = self()
    ref = make_ref()

    stub(Managoat.Sandbox.Sprites, :exec, fn _handle, cmd, args, _opts ->
      send(test, {:exec, cmd, args})
      {:ok, "", 0}
    end)

    stub(Managoat.Sandbox.Sprites, :write_file, fn _handle, path, body, opts ->
      send(test, {:written, path, IO.iodata_to_binary(body), opts})
      :ok
    end)

    stub(Fountain.Conversations.Provisioning, :write_env_file, fn _handle, pairs ->
      send(test, {:env_file, pairs})
      :ok
    end)

    stub(Managoat.Sandbox.Sprites, :spawn, fn _handle, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    stub(Managoat.Sandbox.Sprites, :write_stdin, fn _command, _data -> :ok end)
    stub(Managoat.Sandbox.Sprites, :close_stdin, fn _command -> :ok end)
    stub(Managoat.Sandbox.Sprites, :stop_command, fn _command -> :ok end)
  end

  defp home(grant), do: "/home/sprite/.codex-grants/#{grant.id}.#{grant.generation}"

  # Everything recorded so far, in order, without waiting on anything.
  defp recorded(acc \\ []) do
    receive do
      message when is_tuple(message) and elem(message, 0) in [:exec, :written, :env_file] ->
        recorded([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "two subscriptions, one sandbox, at the same time",
       %{user: user, sandbox: sandbox} = ctx do
    record_sandbox()

    # Both servers start before either is looked at: they provision on their
    # own processes, against the one machine.
    servers =
      for peer <- ctx.peers do
        {pid, _mon, :alive} =
          start_server(peer.conv, runtime: Managoat.Runtimes.Codex, initial_prompt: "hello")

        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        Map.put(peer, :pid, pid)
      end

    states = for peer <- servers, do: Map.put(peer, :state, :sys.get_state(peer.pid))

    # ── each conversation is pinned to its own grant ──────────────────────────
    for %{state: state, grant: grant} <- states do
      assert %Source{scope: :grant, grant_id: grant_id, generation: generation} =
               state.inference_source

      assert {grant_id, generation} == {grant.id, grant.generation}

      assert state.env_credentials == %{
               codex_chatgpt_access_token: Reserved.placeholder(grant.id)
             }

      assert state.inference_credentials == state.env_credentials
      # The managed grant never enters the ordinary `brokered` map (0052 d6).
      refute Map.has_key?(state.brokered, "CODEX_CHATGPT_ACCESS_TOKEN")
      refute Map.has_key?(state.broker_bindings, "CODEX_CHATGPT_ACCESS_TOKEN")
    end

    # ── neither was refused, and the machine is bound to neither ─────────────
    machine = Repo.reload!(sandbox)
    assert machine.status == "ready"
    assert is_nil(machine.codex_inference_source)

    for %{conv: conv} <- states do
      assert Repo.reload!(conv).status != "failed"
    end

    # Both turns have spawned, so both peers' preparation is behind us.
    assert_receive {:spawned, _, _, first}, 2_000
    assert_receive {:spawned, _, _, second}, 2_000
    told = recorded()

    # ── two account files, two homes, two accounts, two placeholders ─────────
    files =
      for {:written, path, body, opts} <- told, path =~ "auth.json", do: {path, body, opts}

    assert length(files) == 2

    for %{grant: grant} <- states do
      assert {_, body, opts} = Enum.find(files, &(elem(&1, 0) == home(grant) <> "/auth.json"))
      assert opts[:mode] == 0o600

      assert %{
               "auth_mode" => "chatgptAuthTokens",
               "tokens" => %{"access_token" => placeholder, "account_id" => account_id}
             } = Jason.decode!(body)

      assert placeholder == Reserved.placeholder(grant.id)
      assert account_id == grant.account_id
    end

    # Each home was prepared by the constant link script, with its path as an
    # argument, and nothing wrote the shared file.
    linked =
      for {:exec, "sh", ["-c", _script, "sh", "/home/sprite/.codex", home]} <- told, do: home

    assert Enum.sort(linked) == Enum.sort(for %{grant: grant} <- states, do: home(grant))
    refute Enum.any?(files, &(elem(&1, 0) == "/home/sprite/.codex/auth.json"))

    # ── the spawn carries the home; the shared `.env` never does ─────────────
    spawn_envs = for opts <- [first, second], do: Map.new(Keyword.fetch!(opts, :env))

    assert Enum.sort(for env <- spawn_envs, do: env["CODEX_HOME"]) ==
             Enum.sort(for %{grant: grant} <- states, do: home(grant))

    for env <- spawn_envs do
      %{grant: grant} = Enum.find(states, &(home(&1.grant) == env["CODEX_HOME"]))
      assert env["CODEX_CHATGPT_ACCESS_TOKEN"] == Reserved.placeholder(grant.id)
      refute Map.has_key?(env, "OPENAI_API_KEY")

      assert Jason.decode!(env["CODEX_CONFIG"])["model_providers"]["fountain_openai_http"][
               "base_url"
             ] == "https://chatgpt.com/backend-api/codex"
    end

    env_files = for {:env_file, pairs} <- told, do: pairs
    assert env_files != []

    for pairs <- env_files, {key, value} <- pairs do
      refute key in ["CODEX_HOME", "CODEX_CHATGPT_ACCESS_TOKEN"]
      refute to_string(value) =~ ".codex-grants"
    end

    # ── a broker session each, pinned to its own grant, holding no bearer ────
    for %{conv: conv, grant: grant, access: access} <- states do
      assert [%Session{} = session] =
               Repo.all(from s in Session, where: s.conversation_id == ^conv.id)

      assert session.managed_grant_id == grant.id
      assert session.managed_grant_generation == grant.generation
      assert session.managed_grant_owner_id == user.id
      assert session.managed_identity == grant.account_id

      assert {:ok, %ProtectedCredential{bearer: ^access, identity: identity}} =
               Sessions.authorize({:managed, session.id}, @protected)

      assert identity == grant.account_id

      {:ok, rules} =
        Fountain.Crypto.decrypt(session.rules_ciphertext, <<0::256>>, "fountain.broker.rules")

      refute rules =~ access
      refute rules =~ "codex_chatgpt_access_token"
    end

    # ── and the bearer is nowhere a conversation can reach ───────────────────
    for %{state: state, conv: conv, grant: grant} <- states, %{access: access} <- states do
      refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ access
      refute access in Redaction.lookup(conv.id)
      # A placeholder is not a secret, and ends in `__` (#2366).
      refute Reserved.placeholder(grant.id) in Redaction.lookup(conv.id)

      for event <- Conversations._unsafe_list_log_events(conv.id) do
        refute to_string(event.data) =~ access
      end
    end
  end

  # ADR 0060's second acceptance test: refresh between prompts on one while
  # the other is idle.
  test "a prompt renews its own subscription, by id and generation; the idle one does not move",
       %{user: user} = ctx do
    record_sandbox()
    [_personal, work] = ctx.peers

    # A third subscription whose token is inside its refresh margin.
    stale = access_token(60, %{"subscription" => "Side"})

    side =
      user_grant!(user.id, %{name: "Side", access_token: stale, refresh_token: "rt_side"})

    {:ok, set} = InferenceCredentials.create_set(user.id, "Side set")
    {:ok, set} = InferenceCredentials.set_grant(set, side.id)

    conv =
      insert_conversation(
        user_id: user.id,
        agent: Fountain.Agents._unsafe_get_agent!(work.conv.agent_id),
        sandbox: ctx.sandbox,
        runtime: "codex",
        status: "idle",
        inference_credential_id: set.id
      )

    [side_pid, _work_pid] =
      for c <- [conv, work.conv] do
        {pid, _mon, :alive} = start_server(c, runtime: Managoat.Runtimes.Codex)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        pid
      end

    sessions = Repo.all(from s in Session, order_by: s.id)
    work_row = Repo.get!(Fountain.PlatformChatGPT.Account, work.grant.id)
    before = :sys.get_state(side_pid)
    renewed = access_token(7_200, %{"subscription" => "Side", "renewed" => true})

    stub_refresh(%{
      expect_refresh: "rt_side",
      access_token: renewed,
      id_token: id_token(%{account_id: side.account_id})
    })

    assert :ok = GenServer.call(side_pid, {:send_prompt, "next", []})
    assert_receive {:spawned, _, _, _}, 2_000

    # Renewed in place: same grant, same generation, a new token.
    row = Repo.get!(Fountain.PlatformChatGPT.Account, side.id)
    assert row.generation == side.generation
    assert row.lock_version == side.lock_version + 1

    side_session = Enum.find(sessions, &(&1.conversation_id == conv.id))

    assert {:ok, %ProtectedCredential{bearer: ^renewed}} =
             Sessions.authorize({:managed, side_session.id}, @protected)

    # Rotation reached the proxy through the grant row. No session was
    # rewritten or re-minted, the conversation still holds no token, and its
    # `brokered` map never gained the managed key.
    assert Repo.all(from s in Session, order_by: s.id) == sessions
    state = :sys.get_state(side_pid)
    assert state.broker == before.broker
    assert state.env_credentials == before.env_credentials
    refute Map.has_key?(state.brokered, "CODEX_CHATGPT_ACCESS_TOKEN")
    refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ renewed

    # The idle peer's subscription was not read for renewal, let alone written.
    assert Repo.get!(Fountain.PlatformChatGPT.Account, work.grant.id) == work_row
  end

  test "disconnecting one leaves the other's conversation, session and grant untouched",
       %{user: user} = ctx do
    record_sandbox()
    [personal, work] = ctx.peers

    pids =
      for peer <- ctx.peers do
        {pid, _mon, :alive} = start_server(peer.conv, runtime: Managoat.Runtimes.Codex)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        pid
      end

    [personal_pid, work_pid] = pids
    work_row = Repo.get!(Fountain.PlatformChatGPT.Account, work.grant.id)
    work_session = Repo.one!(from s in Session, where: s.conversation_id == ^work.conv.id)

    :ok = ChatGPTAccounts.disconnect_for_user(personal.grant.id, user.id)

    # The disconnected one: its session is revoked in the same transaction,
    # the Codex backend is closed to it, and its next turn is refused by name.
    personal_session = Repo.one!(from s in Session, where: s.conversation_id == ^personal.conv.id)
    assert %DateTime{} = personal_session.managed_revoked_at
    assert {:error, :denied} = Sessions.authorize({:managed, personal_session.id}, @protected)

    assert {:error, {:chatgpt_grant_unusable, %{name: "Personal", reason: :disconnected}}} =
             GenServer.call(personal_pid, {:send_prompt, "again", []})

    # The other: the same row, the same session, the same bearer, and a turn.
    assert Repo.get!(Fountain.PlatformChatGPT.Account, work.grant.id) == work_row
    assert Repo.get!(Session, work_session.id) == work_session
    access = work.access

    assert {:ok, %ProtectedCredential{bearer: ^access}} =
             Sessions.authorize({:managed, work_session.id}, @protected)

    assert :ok = GenServer.call(work_pid, {:send_prompt, "carry on", []})
    assert_receive {:spawned, _, _, opts}, 2_000
    assert Map.new(Keyword.fetch!(opts, :env))["CODEX_HOME"] == home(work.grant)
  end

  # The fence at issuance refuses between this server resolving its source and
  # minting its session. A broker failure is otherwise transient; this one is
  # the grant's, permanent, and said in the words the turn's refusal uses.
  describe "a grant that ended between the resolve and the broker session" do
    # The grant's lifecycle write lands just before the mint, every time.
    defp before_the_mint(conv, fun) do
      stub(Fountain.Broker, :prepare, fn conv_id, brokered, bindings, opts ->
        if conv_id == conv.id, do: fun.()
        Mimic.call_original(Fountain.Broker, :prepare, [conv_id, brokered, bindings, opts])
      end)
    end

    defp failed_stage(conv, stage) do
      conv.id
      |> Conversations._unsafe_list_log_events()
      |> Enum.find(&(&1.kind == "stage" and &1.stage == stage and &1.state == "failed"))
      |> Map.fetch!(:data)
      |> Jason.decode!()
    end

    test "a wake says which grant and why, and is not retryable", %{user: user} = ctx do
      record_sandbox()
      [personal, work] = ctx.peers

      before_the_mint(personal.conv, fn ->
        :ok = ChatGPTAccounts.disconnect_for_user(personal.grant.id, user.id)
      end)

      {_pid, ref, _} = start_server(personal.conv, runtime: Managoat.Runtimes.Codex)
      assert_stopped(ref)

      assert %{
               "reason" => "chatgpt_grant_unusable",
               "grant_reason" => "disconnected",
               "grant_id" => grant_id,
               "message" => message,
               "retryable" => false,
               "node" => _
             } = failed_stage(personal.conv, "reattach")

      assert grant_id == personal.grant.id
      assert message =~ "Personal"
      refute message =~ "managed_grant_inactive"

      # A reconnect is a new sign-in: the grant is fine, this source is not it.
      before_the_mint(work.conv, fn ->
        {:ok, _} =
          ChatGPTAccounts.reconnect_for_user(work.grant.id, user.id, %{
            access_token: access_token(),
            refresh_token: "rt_again",
            id_token: id_token(%{account_id: work.grant.account_id})
          })
      end)

      {_pid, ref, _} = start_server(work.conv, runtime: Managoat.Runtimes.Codex)
      assert_stopped(ref)

      assert %{"reason" => "inference_source_changed", "retryable" => false} =
               failed_stage(work.conv, "reattach")

      # Nothing about the machine: its row is as it was, for the next wake.
      assert Repo.reload!(ctx.sandbox).status == "ready"
      assert Repo.aggregate(Session, :count) == 0
    end

    test "a first provision says the same", %{user: user} = ctx do
      record_sandbox()
      [personal, _work] = ctx.peers
      pending = insert_sandbox(user_id: user.id, agent_id: personal.conv.agent_id)

      conv =
        insert_conversation(
          user_id: user.id,
          agent: Fountain.Agents._unsafe_get_agent!(personal.conv.agent_id),
          sandbox: pending,
          runtime: "codex",
          inference_credential_id: personal.conv.inference_credential_id
        )

      before_the_mint(conv, fn ->
        :ok = ChatGPTAccounts.disconnect_for_user(personal.grant.id, user.id)
      end)

      {_pid, ref, _} = start_server(conv, runtime: Managoat.Runtimes.Codex)
      assert_stopped(ref)

      assert %{
               "reason" => "chatgpt_grant_unusable",
               "grant_reason" => "disconnected",
               "retryable" => false,
               "message" => message
             } = failed_stage(conv, "provision")

      assert message =~ "Personal"
      assert Repo.reload!(conv).status == "failed"
    end
  end

  test "a session re-minted for a grant disconnected since is refused: no fresh session for it",
       %{user: user} = ctx do
    record_sandbox()
    [personal, _work] = ctx.peers
    {pid, _mon, :alive} = start_server(personal.conv, runtime: Managoat.Runtimes.Codex)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    state = :sys.get_state(pid)

    :ok = ChatGPTAccounts.disconnect_for_user(personal.grant.id, user.id)

    # Every issuance path passes the grant, so every one meets the fence.
    assert {:error, {:broker, :session, :managed_grant_inactive}} =
             Fountain.Conversations.Egress.reprepare(state)

    assert {:error, {:broker, :session, :managed_grant_inactive}} =
             Fountain.Conversations.Egress.prepare_state(%{state | broker: nil})

    assert Repo.aggregate(
             from(s in Session, where: s.conversation_id == ^personal.conv.id),
             :count
           ) ==
             1
  end
end
