defmodule Fountain.Conversations.ReapplySkillsPerRuntimeTest do
  # #2514: each runtime on a machine reconciles its own skills root against
  # its own record, and leaves every other runtime's record alone.
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.{Reapply, Sandbox}
  alias Fountain.Machines.Machine

  setup do
    user = insert_verified_user()
    claude_skills = [%{"name" => "claude-one", "content" => "# c"}]
    codex_skills = [%{"name" => "codex-one", "content" => "# x"}]

    claude = insert_agent(user_id: user.id, skills: claude_skills)

    codex =
      insert_agent(
        user_id: user.id,
        runtime: "codex",
        model: "openai/gpt-5.5-codex",
        skills: codex_skills
      )

    sandbox =
      insert_sandbox(user_id: user.id, agent_id: claude.id, status: "ready", runtime: "claude")

    claude_conv = insert_conversation(user_id: user.id, agent: claude, sandbox: sandbox)
    codex_conv = insert_conversation(user_id: user.id, agent: codex, sandbox: sandbox)

    test = self()

    stub(Fountain.SandboxSkills, :reconcile, fn _handle, runtime, skills, previous ->
      send(test, {:reconciled, runtime, skills, previous})
      :ok
    end)

    %{
      sandbox: sandbox,
      claude: claude,
      codex: codex,
      claude_conv: claude_conv,
      codex_conv: codex_conv,
      claude_skills: claude_skills,
      codex_skills: codex_skills
    }
  end

  test "two runtimes on one machine reconcile against, and record, only their own", ctx do
    assert :ok = Reapply.mount_skills(:handle, ctx.claude_conv, ctx.claude)
    claude_skills = ctx.claude_skills
    assert_received {:reconciled, "claude", ^claude_skills, nil}

    # The codex pass does not read claude's record as its own.
    assert :ok = Reapply.mount_skills(:handle, ctx.codex_conv, ctx.codex)
    codex_skills = ctx.codex_skills
    assert_received {:reconciled, "codex", ^codex_skills, nil}

    assert record(ctx) == %{"claude" => claude_skills, "codex" => codex_skills}

    # A later claude pass sees what claude put there, and replaces only that.
    replaced = [%{"name" => "claude-two", "content" => "# c2"}]
    {:ok, claude} = Agents.update_agent(ctx.claude, %{skills: replaced})

    assert :ok = Reapply.mount_skills(:handle, ctx.claude_conv, claude)
    assert_received {:reconciled, "claude", ^replaced, ^claude_skills}

    assert record(ctx) == %{"claude" => replaced, "codex" => codex_skills}
  end

  test "a failed reconciliation records nothing for its runtime or any other", ctx do
    {:ok, _} = Machine.retarget(ctx.sandbox.id, %{applied_skills: {"codex", ctx.codex_skills}})

    stub(Fountain.SandboxSkills, :reconcile, fn _, _, _, _ -> {:error, :offline} end)

    assert {:error, :offline} = Reapply.mount_skills(:handle, ctx.claude_conv, ctx.claude)
    assert record(ctx) == %{"codex" => ctx.codex_skills}
  end

  test "an identity move carries only the conversation's own runtime's record", ctx do
    {:ok, _} =
      Machine.retarget(ctx.sandbox.id, %{applied_skills: {"codex", ctx.codex_skills}})

    # The claude conversation has no record of its own and no Agent version,
    # so there is nothing to carry for claude, and codex's stays as it was.
    assert :ok =
             Reapply.update_identity(ctx.claude_conv, ctx.claude, nil, nil)

    assert record(ctx) == %{"codex" => ctx.codex_skills}
    assert Sandbox.applied_skills(sandbox(ctx), "claude") == nil
  end

  test "retarget refuses a skills record that names no runtime", ctx do
    assert {:error, {:invalid, :applied_skills}} =
             Machine.retarget(ctx.sandbox.id, %{applied_skills: ctx.claude_skills})

    assert {:error, {:invalid, :applied_skills}} =
             Machine.retarget(ctx.sandbox.id, %{applied_skills: {"claude", nil}})
  end

  defp sandbox(ctx), do: Conversations._unsafe_get_sandbox!(ctx.sandbox.id)
  defp record(ctx), do: sandbox(ctx).applied_skills_by_runtime
end
