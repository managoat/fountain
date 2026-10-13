defmodule Fountain.Conversations.LiveSecretsTest do
  # Which servers a vault or environment secret write tells (#2548). The
  # rewrite each server then does is `conversation_server_broker_test.exs`'s;
  # here the servers are stand-ins that report the cast, so the question is
  # only who hears it: the live conversations on that source, the owner's
  # alone.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Environments
  alias Fountain.Vaults

  @dek <<0::256>>

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    vault = insert_vault(user_id: user.id)
    {:ok, user: user, agent: agent, vault: vault}
  end

  # Every conversation in `convs` gets a stand-in server that tells the test
  # which conversation a cast reached; any other id has no server.
  defp live(convs) do
    test = self()

    servers =
      Map.new(convs, fn conv ->
        id = conv.id

        pid =
          spawn_link(fn ->
            receive_loop = fn loop ->
              receive do
                {:"$gen_cast", msg} ->
                  send(test, {:told, id, msg})
                  loop.(loop)
              end
            end

            receive_loop.(receive_loop)
          end)

        {id, pid}
      end)

    stub(ConversationServer, :whereis, &Map.get(servers, &1))
  end

  defp write(vault, value),
    do: Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => value}, @dek)

  test "a vault secret write tells the live conversations on that vault", %{
    user: user,
    agent: agent,
    vault: vault
  } do
    on_vault = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id)
    idle = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id, status: "idle")
    elsewhere = insert_conversation(user_id: user.id, agent: agent)

    done =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        vault_id: vault.id,
        status: "terminated"
      )

    live([on_vault, idle, elsewhere, done])

    assert {:ok, _} = write(vault, "ghp_new")

    assert_receive {:told, id, :refresh_secrets} when id == on_vault.id
    assert_receive {:told, id, :refresh_secrets} when id == idle.id
    refute_receive {:told, _, _}, 100
  end

  test "a delete tells them too", %{user: user, agent: agent, vault: vault} do
    {:ok, secret} = write(vault, "ghp_new")
    conv = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id)
    live([conv])

    assert {:ok, _} = Vaults.delete_secret(vault, secret)
    assert_receive {:told, id, :refresh_secrets} when id == conv.id
  end

  test "a vault with no live conversation takes the write as before", %{
    user: user,
    agent: agent,
    vault: vault
  } do
    # A row, but no server: the next wake reads the vault at init.
    insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id, status: "idle")
    stub(ConversationServer, :whereis, fn _ -> nil end)

    assert {:ok, _} = write(vault, "ghp_new")
    assert [%{key: "GITHUB_TOKEN"}] = Vaults._unsafe_list_secrets(vault)
  end

  test "another tenant's conversations are never told", %{
    user: user,
    agent: agent,
    vault: vault
  } do
    mine = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id)

    other = insert_verified_user()
    other_agent = insert_agent(user_id: other.id)
    their_vault = insert_vault(user_id: other.id)

    theirs =
      insert_conversation(user_id: other.id, agent: other_agent, vault_id: their_vault.id)

    # A row that names this tenant's vault from another tenant: the
    # ownership checks refuse one, and if one slipped past them it is still
    # not this write's to reach.
    stray = insert_conversation(user_id: other.id, agent: other_agent, vault_id: vault.id)

    live([mine, theirs, stray])

    assert {:ok, _} = write(vault, "ghp_new")

    assert_receive {:told, id, :refresh_secrets} when id == mine.id
    refute_receive {:told, _, _}, 100
  end

  test "an environment secret write tells the conversations that run on it", %{user: user} do
    env = insert_env(user_id: user.id)
    on_agent_env = insert_agent(user_id: user.id, environment_id: env.id)
    plain_agent = insert_agent(user_id: user.id)
    other_env = insert_env(user_id: user.id)

    # The agent's environment, by default.
    inherited = insert_conversation(user_id: user.id, agent: on_agent_env)
    # The conversation's own, over its agent's.
    named = insert_conversation(user_id: user.id, agent: plain_agent, environment_id: env.id)
    # Its own override names another one, so the agent's is not in use.
    overridden =
      insert_conversation(user_id: user.id, agent: on_agent_env, environment_id: other_env.id)

    live([inherited, named, overridden])

    assert {:ok, _} =
             Environments.upsert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "x"}, @dek)

    assert_receive {:told, id, :refresh_secrets} when id == inherited.id
    assert_receive {:told, id, :refresh_secrets} when id == named.id
    refute_receive {:told, _, _}, 100
  end
end
