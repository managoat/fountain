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

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "conversation-skills-test"}

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
      {:ok, []}
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

  # #2971: a re-pin whose fetch failed used to be recorded as applied, so no
  # later wake saw the ref as moved and the old copy stayed for good.
  test "a re-pin whose fetch fails keeps the old record and is retried on the next wake", ctx do
    test = self()
    kept = %{"source" => "obra/superpowers", "name" => "brainstorming"}
    old = %{"source" => "anthropics/skills", "name" => "internal-comms", "ref" => "v1"}
    moved = %{old | "ref" => "v2"}
    added = %{"source" => "owner/new", "name" => "fresh"}
    {:ok, _} = Machine.record_skills(ctx.sandbox.id, [kept, old])

    # The real reconciliation, against a disk that holds every recorded skill.
    stub(Fountain.SandboxSkills, :reconcile, fn handle, runtime, skills, previous, opts ->
      send(test, {:reconcile_opts, opts})

      Mimic.call_original(Fountain.SandboxSkills, :reconcile, [
        handle,
        runtime,
        skills,
        previous,
        opts
      ])
    end)

    stub(Managoat.Sandbox, :write_file, fn _, _, _ -> :ok end)

    stub(Managoat.Sandbox, :exec, fn _, "bash", ["-c", script], _ ->
      if script =~ "basename", do: {:ok, "brainstorming\ninternal-comms\n", 0}, else: {:ok, "", 0}
    end)

    stub(Managoat.Runtimes.Skills, :stage_github, fn _, _, entries, _ ->
      Enum.map(entries, &{&1, {:error, :offline}})
    end)

    {:ok, agent} = Agents.update_agent(ctx.agent, %{skills: [kept, moved, added]})

    assert :ok = Skills.mount(@handle, ctx.conv, agent, [])
    assert_received {:reconcile_opts, opts}
    assert opts[:refresh] == [moved, added]
    # `added` never installed, so it is not recorded either.
    assert record(ctx) == [kept, old]

    # The next wake still sees the ref as moved, and this time the fetch works.
    stub(Managoat.Runtimes.Skills, :stage_github, fn _, _, entries, _ ->
      Enum.map(entries, &{&1, {:ok, []}})
    end)

    assert :ok = Skills.mount(@handle, ctx.conv, agent, [])
    assert_received {:reconcile_opts, opts}
    assert opts[:refresh] == [moved, added]
    assert record(ctx) == [kept, moved, added]
  end

  test "record_skills/2 refuses a terminal machine", ctx do
    Repo.update!(Ecto.Changeset.change(sandbox(ctx), status: "terminated"))

    assert {:error, :sandbox_unavailable} = Machine.record_skills(ctx.sandbox.id, ctx.skills)
  end

  defp sandbox(ctx), do: Conversations._unsafe_get_sandbox!(ctx.sandbox.id)
  defp record(ctx), do: sandbox(ctx).applied_skills
end
