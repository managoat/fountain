defmodule Fountain.Conversations.SkillsTest do
  # The wake's skills reconciliation (`Fountain.Conversations.Skills.mount/3`):
  # it reconciles the conversation's runtime's skills root against the
  # machine's one record, and advances the record only on success.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.Skills
  alias Fountain.Machines.Machine

  setup do
    user = insert_verified_user()
    skills = [%{"name" => "codex-one", "content" => "# x"}]

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "codex",
        model: "openai/gpt-5.5-codex",
        skills: skills
      )

    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox)

    test = self()

    stub(Fountain.SandboxSkills, :reconcile, fn _handle, runtime, skills, previous ->
      send(test, {:reconciled, runtime, skills, previous})
      :ok
    end)

    %{sandbox: sandbox, agent: agent, conv: conv, skills: skills}
  end

  test "reconciles the conversation's runtime against the machine's record, then records", ctx do
    assert :ok = Skills.mount(:handle, ctx.conv, ctx.agent)
    skills = ctx.skills
    assert_received {:reconciled, "codex", ^skills, nil}
    assert record(ctx) == skills

    # The next pass sees what the last one put there, and replaces it.
    replaced = [%{"name" => "codex-two", "content" => "# x2"}]
    {:ok, agent} = Agents.update_agent(ctx.agent, %{skills: replaced})

    assert :ok = Skills.mount(:handle, ctx.conv, agent)
    assert_received {:reconciled, "codex", ^replaced, ^skills}
    assert record(ctx) == replaced
  end

  test "a failed reconciliation leaves the record as it was", ctx do
    {:ok, _} = Machine.record_skills(ctx.sandbox.id, ctx.skills)

    stub(Fountain.SandboxSkills, :reconcile, fn _, _, _, _ -> {:error, :offline} end)
    {:ok, agent} = Agents.update_agent(ctx.agent, %{skills: []})

    assert {:error, :offline} = Skills.mount(:handle, ctx.conv, agent)
    assert record(ctx) == ctx.skills
  end

  test "record_skills/2 refuses a terminal machine", ctx do
    Repo.update!(Ecto.Changeset.change(sandbox(ctx), status: "terminated"))

    assert {:error, :sandbox_unavailable} = Machine.record_skills(ctx.sandbox.id, ctx.skills)
  end

  defp sandbox(ctx), do: Conversations._unsafe_get_sandbox!(ctx.sandbox.id)
  defp record(ctx), do: sandbox(ctx).applied_skills
end
