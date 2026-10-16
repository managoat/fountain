defmodule Fountain.Conversations.ConversationServerCallbackHandoverTest do
  # #2835: a turn running when a deploy stops its server keeps running in the
  # sandbox, and its adapter holds the server's callback key in its
  # `MANAGOAT_TOKEN` and in any `"auth": "conversation"` MCP headers (ADR
  # 0086). A graceful stop hands that key over instead of revoking it; the
  # server that reattaches the turn revokes it when the turn ends. Every
  # other stop revokes as before, and a reattached idle peer never carries
  # the next turn on the old key.
  use Fountain.ConversationServerCase

  import Ecto.Query, only: [from: 2]
  import Fountain.ConversationServerCase.ACP

  alias Fountain.{Accounts, Repo}
  alias Fountain.Accounts.ApiKey
  alias Fountain.Audit.Event
  alias Fountain.Conversations.{CallbackKey, Connection, Turn}
  alias Managoat.Sandbox.Session

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent: agent)
    {:ok, user: user, agent: agent, conv: conv}
  end

  defp key_revoked?(key_id), do: Repo.get!(ApiKey, key_id).revoked_at != nil

  defp reload(conv), do: Conversations._unsafe_get_conversation!(conv.id)

  defp revocations(user_id, key_id) do
    Repo.all(
      from e in Event,
        where:
          e.user_id == ^user_id and e.action == "api_key.revoked" and
            e.resource_id == ^key_id
    )
  end

  # The first server, with its turn's `session/prompt` written and unanswered.
  defp start_running_turn(conv) do
    stub_happy_sprite()
    ref = stub_acp_transport()
    {pid, mon, :alive} = start_server(conv, initial_prompt: "long task")
    prompt_id = drive_to_prompt(pid, ref)
    assert_receive {:spawned, _cmd, _args, _opts}

    state = :sys.get_state(pid)
    assert %Turn{id: turn_id} = state.current_turn
    assert is_binary(state.callback_api_key_id)
    {pid, mon, prompt_id, turn_id, state}
  end

  # The second server, reattaching to the adapter session the first one left.
  defp reattach(conv) do
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _h ->
      {:ok, [%Session{id: "live", command: "env MANAGOAT_CONVERSATION_ID=#{conv.id} adapter"}]}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _h, "live", _opts ->
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    {pid, _mon, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, ref}
  end

  test "a graceful stop mid-turn hands the key over, and the reattaching server revokes it at turn end",
       %{user: user, agent: agent, conv: conv} do
    {pid, mon, prompt_id, turn_id, first} = start_running_turn(conv)
    key_id = first.callback_api_key_id

    # A deploy: the supervisor's shutdown.
    Process.exit(pid, :shutdown)
    assert_stopped(mon)

    # The adapter in the sandbox is still working on this key.
    refute key_revoked?(key_id)

    assert {:ok, _user, %ApiKey{id: ^key_id}} =
             Accounts.authenticate_api_key(first.callback_token)

    assert reload(conv).handover_callback_api_key_id == key_id
    assert Repo.get!(Turn, turn_id).status == "running"
    assert revocations(user.id, key_id) == []

    {pid2, ref2} = reattach(conv)
    second = :sys.get_state(pid2)
    assert second.current_turn.id == turn_id
    assert second.handover_callback_key == {key_id, turn_id}
    assert is_binary(second.callback_api_key_id) and second.callback_api_key_id != key_id

    # While the turn runs the handed-over key still names its conversation,
    # so `/api/auth/me` binds it and a sub-agent spawn keeps its depth.
    refute key_revoked?(key_id)
    assert Conversations.get_conversation_for_callback_key(key_id, user.id).id == conv.id

    reply(pid2, ref2, prompt_id, %{"stopReason" => "end_turn"})

    assert Repo.get!(Turn, turn_id).status == "completed"
    assert key_revoked?(key_id)
    assert reload(conv).handover_callback_api_key_id == nil
    assert Conversations.get_conversation_for_callback_key(key_id, user.id) == nil
    assert :sys.get_state(pid2).handover_callback_key == nil
    refute key_revoked?(second.callback_api_key_id)

    # Audited once, by the server, from its new place.
    assert [%Event{actor: "system:conversation_server"}] = revocations(user.id, key_id)

    # The reattached peer is idle on the old key, and this agent names no
    # `"auth": "conversation"` server: it is still closed before the next
    # turn, which spawns afresh with the current key in its env.
    idle = :sys.get_state(pid2)
    assert is_pid(idle.acp_peer)
    assert Connection.stale_reason(idle, false, reload(conv), agent) == "callback_key_rotated"

    assert :ok = GenServer.call(pid2, {:send_prompt, "next", []})
    assert_receive {:spawned, _cmd, _args, opts}, 2_000
    assert {"MANAGOAT_TOKEN", second.callback_token} in Keyword.fetch!(opts, :env)
  end

  test "a crash mid-turn still revokes the key", %{conv: conv} do
    {pid, mon, _prompt_id, _turn_id, first} = start_running_turn(conv)

    Process.exit(pid, :some_linked_crash)
    assert assert_stopped(mon) == :some_linked_crash

    assert key_revoked?(first.callback_api_key_id)
    assert reload(conv).handover_callback_api_key_id == nil
  end

  test "a graceful stop with no turn running still revokes the key", %{conv: conv} do
    stub_happy_sprite()
    {pid, mon, :alive} = start_server(conv)
    key_id = :sys.get_state(pid).callback_api_key_id

    Process.exit(pid, :shutdown)
    assert_stopped(mon)

    assert key_revoked?(key_id)
    assert reload(conv).handover_callback_api_key_id == nil
  end

  test "a reattach that finds no turn to take back revokes the handed-over key at once",
       %{conv: conv} do
    {pid, mon, _prompt_id, turn_id, first} = start_running_turn(conv)
    Process.exit(pid, :shutdown)
    assert_stopped(mon)

    # The adapter's session is gone by the time the next server looks.
    Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _h -> {:ok, []} end)
    {pid2, _mon, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    assert Repo.get!(Turn, turn_id).status == "interrupted"
    assert key_revoked?(first.callback_api_key_id)
    assert reload(conv).handover_callback_api_key_id == nil
    assert :sys.get_state(pid2).handover_callback_key == nil
  end

  describe "duplicate servers (#367)" do
    test "a dying duplicate hands over nothing and revokes nothing of the survivor's",
         %{conv: conv} do
      {pid, mon, _prompt_id, _turn_id, loser} = start_running_turn(conv)

      # The survivor rotated: the row names a key the loser did not mint.
      {:ok, {%ApiKey{id: survivors_key}, _raw}} =
        Accounts.create_api_key(conv.user_id, "sprite:winner", CallbackKey.api_key_opts())

      {:ok, _} = Conversations.update_conversation(conv, %{callback_api_key_id: survivors_key})

      Process.exit(pid, :shutdown)
      assert_stopped(mon)

      refute key_revoked?(survivors_key)
      assert reload(conv).handover_callback_api_key_id == nil
      # The loser's own key was already superseded; as before, it goes inert
      # at its `expires_at`.
      refute key_revoked?(loser.callback_api_key_id)
    end

    test "a reattached turn's end revokes only a handed-over key, never the row's live one",
         %{user: user, agent: agent} do
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      {:ok, {%ApiKey{id: survivors_key}, _raw}} =
        Accounts.create_api_key(user.id, "sprite:survivor", CallbackKey.api_key_opts())

      conv =
        insert_conversation(
          agent: agent,
          user_id: user.id,
          sandbox: sandbox,
          status: "running",
          runtime_session_id: "sess_live",
          callback_api_key_id: survivors_key
        )

      turn =
        insert_turn(conv, %{
          status: "running",
          prompt: "long task",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second),
          acp_prompt_id: 4
        })

      stub_happy_sprite()
      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
      {pid, ref} = reattach(conv)

      assert :sys.get_state(pid).current_turn.id == turn.id
      assert :sys.get_state(pid).handover_callback_key == nil

      reply(pid, ref, 4, %{"stopReason" => "end_turn"})

      assert Repo.get!(Turn, turn.id).status == "completed"
      refute key_revoked?(survivors_key), "the reattaching server revoked a live server's key"
    end
  end

  describe "CallbackKey.release_handover/2" do
    test "revokes only while the column still names the key, and once", %{user: user, conv: conv} do
      {:ok, {%ApiKey{id: key_id}, _raw}} =
        Accounts.create_api_key(user.id, "sprite:old", CallbackKey.api_key_opts())

      {:ok, conv} = Conversations.update_conversation(conv, %{callback_api_key_id: key_id})
      assert CallbackKey.hand_over(conv.id, key_id) == :ok
      # A second hand-over never overwrites the first.
      assert CallbackKey.hand_over(conv.id, key_id) == :not_ours

      {:ok, {%ApiKey{id: other}, _raw}} =
        Accounts.create_api_key(user.id, "sprite:other", CallbackKey.api_key_opts())

      assert CallbackKey.release_handover(conv.id, other) == :ok
      refute key_revoked?(other)
      refute key_revoked?(key_id)

      assert CallbackKey.release_handover(conv.id, key_id) == :ok
      assert CallbackKey.release_handover(conv.id, key_id) == :ok
      assert key_revoked?(key_id)
      assert length(revocations(user.id, key_id)) == 1
    end
  end
end
