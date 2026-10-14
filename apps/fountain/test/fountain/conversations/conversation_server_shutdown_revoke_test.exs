defmodule Fountain.Conversations.ConversationServerShutdownRevokeTest do
  # #322: terminate/2 revokes the sprite's callback API key, but without
  # trap_exit a supervisor shutdown (every deploy)
  # skips terminate/2 entirely — leaving a live sprite-scoped tenant
  # credential outstanding for up to 30 days if the conversation is never
  # resumed. init/1 now traps exits so shutdown runs terminate/2.
  use Fountain.ConversationServerCase

  alias Fountain.Accounts.ApiKey

  defp start_provisioned_server do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, ref, :alive} = start_server(conv)
    conv = Conversations._unsafe_get_conversation!(conv.id)
    assert is_binary(conv.callback_api_key_id), "provision should have minted a callback key"
    {pid, ref, conv}
  end

  defp key_revoked?(key_id) do
    %ApiKey{revoked_at: revoked_at} = Repo.get!(ApiKey, key_id)
    revoked_at != nil
  end

  test "a supervisor-style :shutdown exit revokes the callback key" do
    {pid, ref, conv} = start_provisioned_server()
    refute key_revoked?(conv.callback_api_key_id)

    # The exact signal a supervisor sends at teardown. Without trap_exit
    # this killed the process with no terminate/2 — verified against the
    # old code: this test fails there with the key still live.
    Process.exit(pid, :shutdown)
    assert_stopped(ref)

    assert key_revoked?(conv.callback_api_key_id)
  end

  test "a linked crash still takes the server down and revokes on the way" do
    {pid, ref, conv} = start_provisioned_server()

    Process.exit(pid, :some_linked_crash)
    reason = assert_stopped(ref)
    assert reason == :some_linked_crash

    assert key_revoked?(conv.callback_api_key_id)
  end

  test "a dying duplicate does not revoke the surviving server's key" do
    # Horde's CRDT merge mass-terminates duplicate servers, and registry
    # lag makes duplicates real (#367). The loser's terminate/2 used to
    # read callback_api_key_id off the row at call time — revoking whatever
    # key the WINNER had rotated in, so the surviving sprite 401'd on every
    # callback and sub-agent spawn.
    {pid, ref, conv} = start_provisioned_server()
    losers_key = conv.callback_api_key_id

    # A winner rotates: the row now points at a key this server did not mint.
    {:ok, {%Fountain.Accounts.ApiKey{id: winners_key}, _raw}} =
      Fountain.Accounts.create_api_key(
        conv.user_id,
        "sprite:winner",
        Fountain.Conversations.ConversationServer.callback_api_key_opts()
      )

    {:ok, _} = Conversations.update_conversation(conv, %{callback_api_key_id: winners_key})

    Process.exit(pid, :shutdown)
    assert_stopped(ref)

    refute key_revoked?(winners_key), "the loser revoked the winner's live credential"
    # The loser's own key was already superseded by the winner's rotation;
    # nothing revokes it here — it goes inert at expires_at and its row is
    # pruned by RetentionPruner.
    refute key_revoked?(losers_key)
  end

  test "provisioning does not revoke a predecessor's key it did not mint" do
    # The reverse race: a second server starting during the registry-lag
    # window used to revoke the row's key while rotating — pulling the live
    # credential out from under the first server.
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {:ok, {%Fountain.Accounts.ApiKey{id: predecessor_key}, _raw}} =
      Fountain.Accounts.create_api_key(
        user.id,
        "sprite:first",
        Fountain.Conversations.ConversationServer.callback_api_key_opts()
      )

    {:ok, _} = Conversations.update_conversation(conv, %{callback_api_key_id: predecessor_key})

    {pid, _ref, :alive} = start_server(conv)

    refute key_revoked?(predecessor_key),
           "the second server revoked the first server's live credential"

    reloaded = Conversations._unsafe_get_conversation!(conv.id)
    assert is_binary(reloaded.callback_api_key_id)
    assert reloaded.callback_api_key_id != predecessor_key

    GenServer.stop(pid)
  end
end
