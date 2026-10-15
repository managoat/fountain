defmodule Fountain.Conversations.SkillsTest do
  # The wake's skills reconciliation (`Fountain.Conversations.Skills.mount/4`):
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

    stub(Fountain.SandboxSkills, :reconcile, fn _handle, runtime, skills, previous, opts ->
      send(test, {:reconciled, runtime, skills, previous})
      send(test, {:reconcile_opts, opts})
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

    stub(Fountain.SandboxSkills, :reconcile, fn _, _, _, _, _ -> {:error, :offline} end)
    {:ok, agent} = Agents.update_agent(ctx.agent, %{skills: []})

    assert {:error, :offline} = Skills.mount(:handle, ctx.conv, agent)
    assert record(ctx) == ctx.skills
  end

  test "a GitHub install gets the proxy and CA variables, and none of the tenant's", ctx do
    sprite_env = [
      {"NODE_EXTRA_CA_CERTS", "/usr/local/share/ca-certificates/agent-vault-ca.crt"},
      {"SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt"},
      {"DATABASE_PASSWORD", "hunter2"},
      {"HTTPS_PROXY", "http://tok:c-x@broker:8443"},
      {"NO_PROXY", "localhost,127.0.0.1"}
    ]

    assert :ok = Skills.mount(:handle, ctx.conv, ctx.agent, sprite_env)
    assert_received {:reconcile_opts, opts}

    assert opts[:env] == [
             {"NODE_EXTRA_CA_CERTS", "/usr/local/share/ca-certificates/agent-vault-ca.crt"},
             {"SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt"},
             {"HTTPS_PROXY", "http://tok:c-x@broker:8443"},
             {"NO_PROXY", "localhost,127.0.0.1"}
           ]
  end

  test "a GitHub skill is refreshed only when its ref moved from the recorded one", ctx do
    kept = %{"source" => "obra/superpowers"}
    moved = %{"source" => "anthropics/skills", "name" => "internal-comms", "ref" => "v2"}
    added = %{"source" => "owner/new"}

    {:ok, _} =
      Machine.record_skills(ctx.sandbox.id, [
        kept,
        %{"source" => "anthropics/skills", "name" => "internal-comms", "ref" => "v1"}
      ])

    {:ok, agent} = Agents.update_agent(ctx.agent, %{skills: [kept, moved, added]})

    assert :ok = Skills.mount(:handle, ctx.conv, agent, [])
    assert_received {:reconcile_opts, opts}
    # `added` is not on the disk, which the reconciliation finds for itself.
    assert opts[:refresh] == [moved, added]
  end

  test "record_skills/2 refuses a terminal machine", ctx do
    Repo.update!(Ecto.Changeset.change(sandbox(ctx), status: "terminated"))

    assert {:error, :sandbox_unavailable} = Machine.record_skills(ctx.sandbox.id, ctx.skills)
  end

  defp sandbox(ctx), do: Conversations._unsafe_get_sandbox!(ctx.sandbox.id)
  defp record(ctx), do: sandbox(ctx).applied_skills
end
