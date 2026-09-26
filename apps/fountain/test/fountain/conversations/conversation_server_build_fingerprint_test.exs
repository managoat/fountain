defmodule Fountain.Conversations.ConversationServerBuildFingerprintTest do
  # What the disk was built from is recorded on the row when the machine
  # reaches `ready` (#1565). Without it a later reapply must refuse to guess
  # whether the current environment still matches the original build (#2102).
  use Fountain.ConversationServerCase

  alias Fountain.Conversations
  alias Fountain.Conversations.Reapply

  test "a ready machine records the environment digest and the skills mounted on it" do
    stub_happy_sprite()

    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "echo hello")
    skills = [%{"name" => "mine", "content" => "# m"}]

    agent =
      insert_agent(user_id: user.id, runtime: "gemini", environment_id: env.id, skills: skills)

    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, _ref, :alive} = start_server(conv)

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.status == "ready"
    assert sandbox.build_fingerprint == Reapply.fingerprint(env)
    assert sandbox.applied_skills_by_runtime == %{"gemini" => skills}

    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end

  test "waking an older disk reconciles skills without inventing a build fingerprint" do
    stub_happy_sprite()
    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "echo changed-after-original-build")
    agent = insert_agent(user_id: user.id, runtime: "gemini", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "suspended",
        environment_id: env.id,
        agent_id: agent.id,
        build_fingerprint: nil,
        applied_skills_by_runtime: nil
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle",
        agent_version_id: Fountain.Agents._unsafe_current_version_id(agent.id)
      )

    for _wake <- 1..2 do
      {pid, _ref, :alive} = start_server(conv)
      current = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert current.build_fingerprint == nil
      assert current.applied_skills_by_runtime == %{"gemini" => []}
      assert current.id == sandbox.id
      GenServer.stop(pid, :normal)
    end
  end

  test "wake cannot replace unknown historical ownership with an empty applied selection" do
    stub_happy_sprite()

    expect(Fountain.SandboxSkills, :reconcile, 2, fn _handle, _runtime, _skills, nil ->
      {:error, :legacy_skill_ownership_unknown}
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    sandbox = insert_sandbox(user_id: user.id, status: "suspended", agent_id: agent.id)

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle",
        agent_version_id: nil
      )

    for _wake <- 1..2 do
      {pid, _ref, :alive} = start_server(conv)
      current = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert current.build_fingerprint == nil
      assert current.applied_skills_by_runtime == nil
      GenServer.stop(pid, :normal)
    end
  end

  test "a machine built with no environment records the digest that stands for none" do
    stub_happy_sprite()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, _ref, :alive} = start_server(conv)

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.build_fingerprint == Reapply.fingerprint(nil)
    assert sandbox.applied_skills_by_runtime == %{"gemini" => []}

    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end
end
