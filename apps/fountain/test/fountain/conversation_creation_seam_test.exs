defmodule Fountain.ConversationCreationSeamTest do
  # ADR 0038's third funnel step (`onboarding.request_sent`) used to be
  # guaranteed by every create path sharing `Conversations.create_conversation/1`.
  # Admission now writes the conversation row inside a transaction with the
  # sandbox and the execution allowance, so that chokepoint is gone and the
  # guarantee is this test: it drives every door that inserts a conversation and
  # fails if one stops firing the seam.
  #
  # A new create path belongs in `@doors` below. If you are here because this
  # test failed after adding one, the fix is a call to
  # `after_conversation_created/1` once your write has committed — not an
  # entry in an exclusion list, because there isn't one.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.Launch

  setup do
    user = insert_verified_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 20)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        status: "ready"
      )

    stub_server_start(fn _, _ -> {:ok, spawn(fn -> :ok end)} end)
    %{user: user, agent: agent, env: env, sandbox: sandbox}
  end

  @doors [:fresh, :attach, :team]

  for door <- @doors do
    test "the #{door} door reports the conversation it created", ctx do
      owner = self()

      expect(Fountain.Activation, :conversation_created, fn conv ->
        send(owner, {:reported, conv.id})
        :ok
      end)

      {:ok, id} = open(unquote(door), ctx)
      assert_received {:reported, ^id}
    end
  end

  for door <- [:fresh, :attach] do
    test "a rolled-back #{door} write reports nothing", ctx do
      reject(&Fountain.Activation.conversation_created/1)

      stub(Fountain.Conversations.ExecutionAllowance, :new_changeset, fn _, _ ->
        %Fountain.Conversations.ExecutionAllowance{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:limits, "fixture rejection")
      end)

      assert {:error, %Ecto.Changeset{}} = open(unquote(door), ctx)
    end
  end

  defp open(:fresh, ctx) do
    with {:ok, conv} <-
           Launch.start_conversation(%{
             "user_id" => ctx.user.id,
             "agent_id" => ctx.agent.id,
             "sandbox_mode" => "ephemeral"
           }),
         do: {:ok, conv.id}
  end

  defp open(:attach, ctx) do
    with {:ok, conv} <-
           Launch.start_conversation(%{
             "user_id" => ctx.user.id,
             "agent_id" => ctx.agent.id,
             "sandbox_id" => ctx.sandbox.id
           }),
         do: {:ok, conv.id}
  end

  # `open_fresh_conversation/3` reuses a `ready` computer, which is the branch
  # that opens a row through `create_conversation/1`.
  defp open(:team, ctx) do
    insert_conversation(
      user_id: ctx.user.id,
      agent: ctx.agent,
      sandbox: ctx.sandbox,
      status: "idle",
      channel_id: "fountain:team"
    )

    with {:ok, conv} <- Fountain.Team.open_fresh_conversation(ctx.user.id, ctx.agent.id),
         do: {:ok, conv.id}
  end
end
