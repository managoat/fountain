defmodule Fountain.Conversations.WakeCotenantsTest do
  @moduledoc """
  A wake that finds the sprite gone replaces the machine, and the machine's
  owner tells the co-tenants (ADR 0058 stage 8b): `Wake` decides who follows
  onto the replacement and who stays behind, and hands both groups to the
  destroy that retires the old row as its `:notify`. The cast itself is sent
  from `lib/fountain/machines/` only — `direct_writes_test.exs` pins that
  lexically; this drives it.
  """
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Wake

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    other_env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    old =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        status: "ready",
        provider: "sprites"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: old, status: "idle")

    following = insert_conversation(user_id: user.id, agent: agent, sandbox: old, status: "idle")

    stranded =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: old,
        status: "idle",
        environment_id: other_env.id
      )

    # The sprite is gone: the probe says so, and the wake builds a fresh one.
    stub(Managoat.Sandbox, :get, fn _handle -> {:error, :not_found} end)

    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    stub(ConversationServer, :queue_initial_prompt, fn _pid, _prompt -> :ok end)

    {:ok,
     user: user, agent: agent, old: old, conv: conv, following: following, stranded: stranded}
  end

  defp stand_in_server(conversation_id) do
    test = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conversation_id, nil)
           forward_forever(test, conversation_id)
         end},
        id: {:stand_in, conversation_id}
      )

    wait_until(fn -> ConversationServer.whereis(conversation_id) == pid end)
    pid
  end

  # Forwards **every** message, not the first. A stand-in that takes one and
  # exits cannot see a second notice, and round 1 found one: a persistent
  # home's replacement told each co-tenant twice and both pins were blind to
  # it. A real `ConversationServer` stops on the first cast, so the count is
  # only ever visible from here.
  defp forward_forever(test, conversation_id) do
    receive do
      msg ->
        send(test, {:cotenant, conversation_id, msg})
        forward_forever(test, conversation_id)
    end
  end

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline, "condition never held"
      Process.sleep(10)
      wait_until(fun, deadline)
    end
  end

  test "the owner's destroy tells each co-tenant what became of it", ctx do
    stand_in_server(ctx.following.id)
    stand_in_server(ctx.stranded.id)

    {:ok, _} = Wake.wake_conversation(ctx.conv.id, "hello")

    old_id = ctx.old.id
    following_id = ctx.following.id
    stranded_id = ctx.stranded.id

    assert_receive {:cotenant, ^following_id,
                    {:"$gen_cast", {:machine_gone, ^old_id, "replaced", "sprite_gone", _}}},
                   2_000

    assert_receive {:cotenant, ^stranded_id,
                    {:"$gen_cast", {:machine_gone, ^old_id, "reset", "sprite_gone", _}}},
                   2_000

    # Once each. The stand-ins keep receiving, so a second notice would be
    # here to find (round 1, surfaces review).
    refute_receive {:cotenant, _, {:"$gen_cast", {:machine_gone, _, _, _, _}}}, 500

    # And the conversations' side, which stays in `Wake`: the follower is
    # rebound, the stranded one keeps naming the retired row.
    new_id = Conversations._unsafe_get_conversation!(ctx.conv.id).sandbox_id
    refute new_id == old_id
    assert Conversations._unsafe_get_conversation!(ctx.following.id).sandbox_id == new_id
    assert Conversations._unsafe_get_conversation!(ctx.stranded.id).sandbox_id == old_id
    assert Repo.reload!(ctx.old).status == "terminated"
  end

  test "a persistent home's replacement tells each co-tenant once, after it is up", ctx do
    # A persistent home is retired twice on this path: once before the
    # replacement is provisioned, because the partial unique index allows one
    # live home per identity, and once after the new server starts. Round 1
    # found the notices on both — every co-tenant told twice, the first time
    # while there was no machine to follow onto. Only the second retire tells
    # them.
    ctx.old |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()

    stand_in_server(ctx.following.id)
    stand_in_server(ctx.stranded.id)

    {:ok, _} = Wake.wake_conversation(ctx.conv.id, "hello")

    old_id = ctx.old.id
    following_id = ctx.following.id
    stranded_id = ctx.stranded.id

    assert_receive {:cotenant, ^following_id,
                    {:"$gen_cast", {:machine_gone, ^old_id, "replaced", "sprite_gone", _}}},
                   2_000

    assert_receive {:cotenant, ^stranded_id,
                    {:"$gen_cast", {:machine_gone, ^old_id, "reset", "sprite_gone", _}}},
                   2_000

    refute_receive {:cotenant, _, {:"$gen_cast", {:machine_gone, _, _, _, _}}}, 500

    # The notice named a replacement that exists: the follower is on it.
    new_id = Conversations._unsafe_get_conversation!(ctx.conv.id).sandbox_id
    refute new_id == old_id
    assert Conversations._unsafe_get_conversation!(ctx.following.id).sandbox_id == new_id
    assert Repo.reload!(ctx.old).status == "terminated"
  end
end
