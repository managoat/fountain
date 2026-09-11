defmodule Fountain.AuditGuardrailTest do
  @moduledoc """
  The rule this campaign established, enforced (#552).

  #540 found auditing scattered across callers: a blanket plug on the `:api`
  pipeline, a handful of LiveViews that remembered, and seven contexts with no
  audit calls at all. Every fix in that campaign moved the recording **into the
  context function**, so a mutation is audited whichever door it came through.

  That property is invisible to the compiler. Without a test, the next context
  function to be added joins the gap list silently — which is exactly how the
  original gap grew. This file is the guard; ADR 0013 is the decision it
  guards.

  ## Adding a mutation

  If you add a context function that changes tenant-owned state, add it to
  `@must_audit` with a call that exercises it. If it genuinely should not audit
  (high-volume machine state — see the `Fountain.Audit` moduledoc), add it to
  `@deliberately_silent` with the reason, so the exclusion is a decision on the
  record rather than an omission.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{
    Agents,
    Audit,
    Conversations,
    Environments,
    InferenceCredentials,
    OAuth,
    Principals,
    Vaults,
    Webhooks
  }

  # {label, fun/1 taking the user, expected action}
  #
  # Each entry performs the mutation and names the event it must leave. The
  # point is coverage of the *rule*, not of each function's behaviour — the
  # per-child test files cover metadata, actors and redaction in depth.
  @must_audit [
    {"agent create", &__MODULE__.do_agent_create/1, "agent.created"},
    {"agent update", &__MODULE__.do_agent_update/1, "agent.updated"},
    {"agent delete", &__MODULE__.do_agent_delete/1, "agent.deleted"},
    {"agent rollback", &__MODULE__.do_agent_rollback/1, "agent.updated"},
    {"sandbox request enqueue", &__MODULE__.do_sandbox_request_enqueue/1,
     "sandbox_request.enqueued"},
    {"sandbox request cancel", &__MODULE__.do_sandbox_request_cancel/1,
     "sandbox_request.cancelled"},
    {"environment create", &__MODULE__.do_env_create/1, "environment.created"},
    {"environment update", &__MODULE__.do_env_update/1, "environment.updated"},
    {"environment delete", &__MODULE__.do_env_delete/1, "environment.deleted"},
    {"vault create", &__MODULE__.do_vault_create/1, "vault.created"},
    {"vault update", &__MODULE__.do_vault_update/1, "vault.updated"},
    {"vault delete", &__MODULE__.do_vault_delete/1, "vault.deleted"},
    {"api key mint", &__MODULE__.do_key_create/1, "api_key.created"},
    {"api key revoke", &__MODULE__.do_key_revoke/1, "api_key.revoked"},
    {"inference credential write", &__MODULE__.do_cred_write/1, "inference_credential.write"},
    {"inference credential clear", &__MODULE__.do_cred_clear/1, "inference_credential.delete"},
    {"conversation delete", &__MODULE__.do_conv_delete/1, "conversation.deleted"},
    {"conversation caller tools", &__MODULE__.do_caller_tools/1, "conversation.caller_tools_set"},
    {"conversation configuration reapply", &__MODULE__.do_conv_reapply/1,
     "conversation.configuration_reapplied"},
    {"conversation labels", &__MODULE__.do_labels/1, "conversation.labels_set"},
    {"allowance creation", &__MODULE__.do_allowance_creation/1,
     "conversation.execution_allowance_created"},
    {"allowance narrowing", &__MODULE__.do_allowance_narrowing/1,
     "conversation.execution_allowance_narrowed"},
    {"sandbox reset", &__MODULE__.do_sandbox_reset/1, "sandbox.reset"},
    {"sandbox teardown fence", &__MODULE__.do_teardown_fence/1, "sandbox.teardown_requested"},
    {"role change", &__MODULE__.do_role_change/1, "account.role_changed"},
    {"sandbox limit change", &__MODULE__.do_limit_change/1, "account.sandbox_limit_changed"},
    {"suspend", &__MODULE__.do_suspend/1, "account.suspended"},
    {"unsuspend", &__MODULE__.do_unsuspend/1, "account.unsuspended"},
    # Secrets and credentials (#593). These had five and four call sites
    # respectively before the recording moved into the context; the entries
    # below are what stops a sixth from being silent.
    {"environment secret write", &__MODULE__.do_env_secret_write/1, "environment.secret.write"},
    {"environment secret delete", &__MODULE__.do_env_secret_delete/1,
     "environment.secret.delete"},
    {"vault secret write", &__MODULE__.do_vault_secret_write/1, "vault.secret.write"},
    {"vault secret update", &__MODULE__.do_vault_secret_update/1, "vault.secret.update"},
    {"vault secret delete", &__MODULE__.do_vault_secret_delete/1, "vault.secret.delete"},
    {"password reset", &__MODULE__.do_password_reset/1, "auth.password.reset"},
    {"password change", &__MODULE__.do_password_change/1, "auth.password.changed"},
    {"email verification", &__MODULE__.do_verify_email/1, "auth.email.verified"},
    # The Buzz identity events moved with the extension (#1507); they are
    # asserted the same way in apps/fountain_buzz. ADR 0013's actor vocabulary
    # is still the host's and still closed — an extension records through
    # `Fountain.Audit` and gets no trail of its own.
    # Team membership: a teammate is a channel-bound conversation, so add also
    # leaves conversation.created underneath; these are the team-side events.
    {"team member add", &__MODULE__.do_team_add/1, "team.member.added"},
    {"team member remove", &__MODULE__.do_team_remove/1, "team.member.removed"},
    {"team member rename", &__MODULE__.do_team_rename/1, "team.renamed"},
    {"team member rebind", &__MODULE__.do_team_update/1, "team.updated"},
    {"team conversation rotate", &__MODULE__.do_team_rotate/1, "team.conversation.rotated"},
    # Team schedules: a cron that runs a teammate with a prompt. A run leaves
    # conversation events underneath; `.fired` is the schedule-side record.
    {"team schedule create", &__MODULE__.do_schedule_create/1, "team.schedule.created"},
    {"team schedule update", &__MODULE__.do_schedule_update/1, "team.schedule.updated"},
    {"team schedule delete", &__MODULE__.do_schedule_delete/1, "team.schedule.deleted"},
    {"team schedule run", &__MODULE__.do_schedule_run/1, "team.schedule.fired"},
    # Team contacts: a teammate's email address and phone number (flag
    # `team_comms`). Sends through the MCP tools are audited by the controller
    # as `team.contact.sent` — an effect, not tenant state.
    {"team contact provision", &__MODULE__.do_contact_provision/1, "team.contact.provisioned"},
    {"team contact update", &__MODULE__.do_contact_update/1, "team.contact.updated"},
    {"team contact opt-out", &__MODULE__.do_contact_opt_out/1, "team.contact.opted_out"},
    {"team contact opt-in", &__MODULE__.do_contact_opt_in/1, "team.contact.opted_in"},
    {"team contact release", &__MODULE__.do_contact_release/1, "team.contact.released"},
    {"runner register", &__MODULE__.do_runner_register/1, "runner.registered"},
    {"runner delete", &__MODULE__.do_runner_delete/1, "runner.deleted"},
    # Outbound webhooks (ADR 0024). The auto-disable path is the one with no
    # human behind it, hence `system:webhook_delivery` in the vocabulary.
    {"webhook endpoint create", &__MODULE__.do_webhook_create/1, "webhook_endpoint.created"},
    {"webhook endpoint update", &__MODULE__.do_webhook_update/1, "webhook_endpoint.updated"},
    {"webhook endpoint delete", &__MODULE__.do_webhook_delete/1, "webhook_endpoint.deleted"},
    {"webhook secret rotate", &__MODULE__.do_webhook_rotate/1, "webhook_endpoint.secret_rotated"},
    {"webhook endpoint disable", &__MODULE__.do_webhook_disable/1, "webhook_endpoint.disabled"},
    {"webhook endpoint enable", &__MODULE__.do_webhook_enable/1, "webhook_endpoint.enabled"},
    # Prepaid credits (ADR 0030). Money in and money out are the two shapes;
    # every reason family maps onto one of five `credit.*` actions.
    # Secret bindings (ADR 0019 gate 1b): where a credential goes is as
    # auditable as the credential's existence.
    {"secret binding create", &__MODULE__.do_binding_create/1, "secret_binding.created"},
    {"secret binding update", &__MODULE__.do_binding_update/1, "secret_binding.updated"},
    {"secret binding delete", &__MODULE__.do_binding_delete/1, "secret_binding.deleted"},
    {"oauth client create", &__MODULE__.do_oauth_client_create/1, "oauth_client.created"},
    {"oauth client update", &__MODULE__.do_oauth_client_update/1, "oauth_client.updated"},
    {"oauth client delete", &__MODULE__.do_oauth_client_delete/1, "oauth_client.deleted"},
    {"connection connect", &__MODULE__.do_connection_connect/1, "connection.created"},
    {"connection revoke", &__MODULE__.do_connection_revoke/1, "connection.revoked"},
    {"connection expire", &__MODULE__.do_connection_expire/1, "connection.expired"},
    # Connection providers (#1186): the tenant's own OAuth apps and the MCP
    # authorization servers Fountain discovered. The secret is never in the trail.
    {"connection provider create", &__MODULE__.do_provider_create/1,
     "connection_provider.created"},
    {"connection provider update", &__MODULE__.do_provider_update/1,
     "connection_provider.updated"},
    {"connection provider delete", &__MODULE__.do_provider_delete/1,
     "connection_provider.deleted"},
    {"credit grant", &__MODULE__.do_credit_grant/1, "credit.granted"},
    {"credit debit", &__MODULE__.do_credit_debit/1, "credit.burned"},
    # OAuth (#1343). The state machine is the managoat_oauth library, which
    # has no Repo call of its own to audit beside; it cannot complete any of
    # these three mutations without calling Fountain.OAuth.Host.audit/3, and
    # that is where the recording lives now. These entries are what prove the
    # host still records them, whichever door the grant came through.
    {"oauth authorize", &__MODULE__.do_oauth_authorize/1, "oauth.authorized"},
    {"oauth device approve", &__MODULE__.do_oauth_device_approve/1, "oauth.device_approved"},
    {"oauth device deny", &__MODULE__.do_oauth_device_deny/1, "oauth.device_denied"},
    # Claimable principals (ADR 0044). The trail is written against the
    # *application* that opened the principal, because a principal that
    # expires unclaimed is a tenant nobody can ever sign in to read it from.
    # The user each entry is exercised with here is that application.
    {"claimable principal create", &__MODULE__.do_claimable_create/1, "claimable_user.created"},
    {"claimable principal claim", &__MODULE__.do_claimable_claim/1, "claimable_user.claimed"},
    {"claimable principal release", &__MODULE__.do_claimable_release/1, "claimable_user.released"}
  ]

  # Documented non-coverage. Mirrors the `Fountain.Audit` moduledoc; if the two
  # ever disagree, the moduledoc is the one to trust and this list is stale.
  @deliberately_silent %{
    "ConversationServer per-turn state" => "high-volume machine state; log_events covers it",
    "Accounts.touch_api_key/1" => "a last-used stamp on every authenticated request",
    "Runners.touch/1 and reconnects" =>
      "a last-seen stamp on every heartbeat; a reconnect refreshes the same row",
    "Conversations.mark_read/2" => "reading is not a state change anyone audits",
    "theme and display preferences" => "not tenant data anyone reconstructs an incident from"
  }

  for {label, fun, action} <- @must_audit do
    test "#{label} leaves an audit event" do
      user = insert_active_user()

      unquote(fun).(user)

      actions =
        user.id
        |> Audit.list_recent_for_user(200)
        |> Enum.map(& &1.action)

      assert unquote(action) in actions, """
      #{unquote(label)} produced no #{unquote(action)} event.

      Mutations audit in the context, not the caller (#540). If this function
      genuinely should not audit, move it to @deliberately_silent with a reason
      and update the Fountain.Audit moduledoc — do not delete the assertion.

      Events seen: #{inspect(actions)}
      """
    end
  end

  test "the exclusion list is documented, not empty" do
    # Guard the guard: an empty list would mean the exclusions had been quietly
    # dropped, and the moduledoc claim would be stale.
    assert map_size(@deliberately_silent) > 0

    for {what, reason} <- @deliberately_silent do
      assert is_binary(reason) and byte_size(reason) > 10,
             "#{what} is excluded from auditing with no stated reason"
    end
  end

  test "every audited context function takes an attribution opts list" do
    # The other half of the rule: a context that audits but cannot be told who
    # the caller was records everything as "self", which is worse than useless
    # on an admin-driven or system-driven path.
    for {mod, fun, arity} <- [
          {Agents, :create_agent, 2},
          {Agents, :update_agent, 3},
          {Agents, :delete_agent, 2},
          {Agents, :rollback_agent, 3},
          {Fountain.SandboxQueue, :enqueue, 2},
          {Fountain.SandboxQueue, :cancel_request, 2},
          {Environments, :create_environment, 2},
          {Environments, :update_environment, 3},
          {Environments, :delete_environment, 2},
          {Vaults, :create_vault, 2},
          {Vaults, :update_vault, 3},
          {Vaults, :delete_vault, 2},
          {InferenceCredentials, :put_credential, 5},
          {Conversations, :start_conversation, 2},
          {Conversations, :_unsafe_fence_sandbox_for_teardown, 2},
          {Conversations, :delete_conversation, 2},
          {Fountain.Team.Comms, :provision_contact, 4},
          {Fountain.Team.Comms, :update_contact, 4},
          {Fountain.Team.Comms, :set_opt_out, 3},
          {Fountain.Team.Comms, :release_contact, 3},
          {Webhooks, :create_endpoint, 3},
          {Webhooks, :update_endpoint, 3},
          {Webhooks, :delete_endpoint, 2},
          {Fountain.OAuth, :authorize, 3},
          {Fountain.OAuth, :approve_device_grant, 3},
          {Fountain.OAuth, :deny_device_grant, 3}
        ] do
      # `Code.ensure_loaded?/1` first: `function_exported?/3` answers about
      # *loaded* modules, so on a seed where this test ran before anything had
      # referenced the context it reported a perfectly present function as
      # missing.
      assert Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity),
             "#{inspect(mod)}.#{fun}/#{arity} is missing — an audited context " <>
               "function must accept an opts list carrying :actor and :request_ip"
    end
  end

  ## ── the mutations ─────────────────────────────────────────────────────────

  defp a_webhook(user) do
    {:ok, {endpoint, _secret}} =
      Webhooks.create_endpoint(user.id, %{"url" => "https://hooks.example.com/f"})

    endpoint
  end

  def do_webhook_create(user), do: a_webhook(user)

  def do_webhook_update(user) do
    {:ok, _} = Webhooks.update_endpoint(a_webhook(user), %{"description" => "ci"})
  end

  def do_webhook_delete(user), do: {:ok, _} = Webhooks.delete_endpoint(a_webhook(user))

  def do_webhook_rotate(user), do: {:ok, {_, _}} = Webhooks.rotate_secret(a_webhook(user))

  def do_webhook_disable(user),
    do: {:ok, _} = Webhooks.disable_endpoint(a_webhook(user), "test")

  def do_webhook_enable(user) do
    {:ok, disabled} = Webhooks.disable_endpoint(a_webhook(user), "test")
    {:ok, _} = Webhooks.enable_endpoint(disabled)
  end

  def do_agent_create(user),
    do: {:ok, _} = Agents.create_agent(agent_attrs(%{"user_id" => user.id}))

  def do_agent_update(user) do
    agent = insert_agent(user_id: user.id)
    {:ok, _} = Agents.update_agent(agent, %{"model" => "anthropic/claude-opus-4-5"})
  end

  def do_agent_delete(user) do
    {:ok, _} = Agents.delete_agent(insert_agent(user_id: user.id))
  end

  def do_agent_rollback(user) do
    agent = insert_agent(user_id: user.id)
    {:ok, _} = Agents.update_agent(agent, %{"description" => "edited"})
    version = Agents.get_agent_version(agent.id, 1, user.id)
    {:ok, _} = Agents.rollback_agent(agent, version)
  end

  def do_sandbox_request_enqueue(user) do
    agent = insert_agent(user_id: user.id)

    {:ok, _} =
      Fountain.SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{"prompt" => "queued work"}
      })
  end

  def do_sandbox_request_cancel(user) do
    agent = insert_agent(user_id: user.id)

    {:ok, request} =
      Fountain.SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{}
      })

    {:ok, _} = Fountain.SandboxQueue.cancel_request(request)
  end

  def do_env_create(user),
    do: {:ok, _} = Environments.create_environment(env_attrs(%{"user_id" => user.id}))

  def do_env_update(user) do
    {:ok, _} =
      Environments.update_environment(insert_env(user_id: user.id), %{"setup_script" => "x"})
  end

  def do_env_delete(user) do
    {:ok, _} = Environments.delete_environment(insert_env(user_id: user.id))
  end

  def do_vault_create(user),
    do: {:ok, _} = Vaults.create_vault(vault_attrs(%{"user_id" => user.id}))

  def do_vault_update(user) do
    {:ok, _} = Vaults.update_vault(insert_vault(user_id: user.id), %{"description" => "x"})
  end

  def do_vault_delete(user) do
    {:ok, _} = Vaults.delete_vault(insert_vault(user_id: user.id))
  end

  def do_binding_create(user) do
    {:ok, _} =
      Fountain.SecretBindings.create_binding(user.id, %{
        "key" => "K",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })
  end

  def do_binding_update(user) do
    {:ok, b} =
      Fountain.SecretBindings.create_binding(user.id, %{
        "key" => "K2",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })

    {:ok, _} = Fountain.SecretBindings.update_binding(b, %{"enabled" => false})
  end

  def do_binding_delete(user) do
    {:ok, b} =
      Fountain.SecretBindings.create_binding(user.id, %{
        "key" => "K3",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })

    {:ok, _} = Fountain.SecretBindings.delete_binding(b)
  end

  def do_connection_connect(user), do: insert_connection(user)

  def do_connection_revoke(user) do
    Req.Test.stub(Fountain.Connections.OAuth, fn conn -> Req.Test.json(conn, %{}) end)
    {:ok, _} = Fountain.Connections.revoke(insert_connection(user))
  end

  # A tenant provider that issued no refresh token: the lapsed access token
  # is the expiry event.
  def do_connection_expire(user) do
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    p = insert_provider(user)
    c = insert_connection(user, provider: p, refresh_token: nil, expires_at: past)
    {:error, :expired} = Fountain.Connections.access_token(c)
  end

  def do_provider_create(user), do: insert_provider(user)

  def do_provider_update(user) do
    {:ok, _} = Fountain.Connections.update_provider(insert_provider(user), %{"name" => "renamed"})
  end

  def do_provider_delete(user) do
    {:ok, _} = Fountain.Connections.delete_provider(insert_provider(user))
  end

  def do_runner_register(user) do
    {:ok, _} = Fountain.Runners.register(user.id, %{"name" => "guard"})
  end

  def do_runner_delete(user) do
    {:ok, runner} = Fountain.Runners.register(user.id, %{"name" => "guard-delete"})
    {:ok, _} = Fountain.Runners.delete_runner(runner)
  end

  def do_key_create(user), do: {:ok, {_, _}} = Fountain.Accounts.create_api_key(user.id, "guard")

  def do_key_revoke(user) do
    {:ok, {key, _}} = Fountain.Accounts.create_api_key(user.id, "guard-revoke")
    {:ok, _} = Fountain.Accounts.revoke_api_key(user.id, key.id)
  end

  def do_cred_write(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-guard")
  end

  def do_cred_clear(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, nil)
  end

  def do_conv_delete(user) do
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id)
    {:ok, _} = Conversations.delete_conversation(conv)
  end

  def do_allowance_creation(user) do
    conv = insert_conversation(user_id: user.id)
    {:ok, _} = Conversations.create_execution_allowance(conv.id, user.id, %{})
  end

  def do_allowance_narrowing(user) do
    conv = insert_conversation(user_id: user.id)

    conv.id
    |> Fountain.Conversations.ExecutionAllowance.new_changeset(%{max_model_turns: 10})
    |> Repo.insert!()

    {:ok, _} = Conversations.narrow_execution_allowance(conv.id, user.id, %{max_model_turns: 2})
  end

  def do_caller_tools(user) do
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent)

    {:ok, _} =
      Conversations.set_caller_tools(conv, [
        %{"name" => "lookup", "description" => "", "parameters" => %{}}
      ])
  end

  def do_labels(user) do
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, _} = Conversations._unsafe_merge_labels(conv, %{"env" => "prod"})
  end

  def do_conv_reapply(user) do
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
    {:ok, _} = Conversations.reapply_conversation(conv)
  end

  def do_teardown_fence(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    {:ok, _} = Conversations._unsafe_fence_sandbox_for_teardown(sandbox)
  end

  def do_sandbox_reset(user) do
    agent = insert_agent(user_id: user.id)

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        provider: "sprites"
      )

    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, _} = Conversations.reset_sandbox(home)
  end

  def do_team_add(user) do
    agent = insert_agent(user_id: user.id)

    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    {:ok, _} = Fountain.Team.add_teammate(user.id, agent.id)
  end

  def do_team_rename(user) do
    agent = insert_agent(user_id: user.id)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    {:ok, _} = Fountain.Team.rename_teammate(user.id, agent.id, "Renamed")
  end

  def do_team_update(user) do
    agent = insert_agent(user_id: user.id)
    vault = insert_vault(user_id: user.id)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    {:ok, _, :updated} =
      Fountain.Team.update_teammate(user.id, agent.id, %{"vault_id" => vault.id})
  end

  def do_team_rotate(user) do
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    insert_conversation(
      user_id: user.id,
      agent: agent,
      sandbox: sandbox,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    {:ok, _} = Fountain.Team.open_fresh_conversation(user.id, agent.id)
  end

  def do_team_remove(user) do
    agent = insert_agent(user_id: user.id)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    :ok = Fountain.Team.remove_teammate(user.id, agent.id)
  end

  defp insert_schedule(user) do
    agent = insert_agent(user_id: user.id)

    {:ok, s} =
      Fountain.Team.Schedules.create_schedule(user.id, %{
        "agent_id" => agent.id,
        "cron" => "0 9 * * *",
        "prompt" => "hello"
      })

    s
  end

  # The flag is flipped for the duration of the call only; the providers are
  # the Req.Test plugs from config/test.exs, stubbed in this process.
  defp with_comms(user, fun) do
    agent = insert_agent(user_id: user.id)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    Req.Test.stub(Fountain.Team.Comms.AgentMail, fn conn ->
      Req.Test.json(conn, %{"inbox_id" => "inbox_g", "email" => "g@agentmail.to"})
    end)

    Req.Test.stub(Fountain.Team.Comms.AgentPhone, fn conn ->
      Req.Test.json(conn, %{"id" => "num_g", "phoneNumber" => "+15550000000"})
    end)

    previous = Application.get_env(:fountain, :feature_flag_overrides)
    Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => true})

    try do
      fun.(agent)
    after
      if previous,
        do: Application.put_env(:fountain, :feature_flag_overrides, previous),
        else: Application.delete_env(:fountain, :feature_flag_overrides)
    end
  end

  def do_contact_provision(user) do
    with_comms(user, fn agent ->
      {:ok, _} =
        Fountain.Team.Comms.provision_contact(user.id, agent.id, %{
          "prompt_from_number" => "+15550001111"
        })
    end)
  end

  def do_contact_update(user) do
    with_comms(user, fn agent ->
      {:ok, _} =
        Fountain.Team.Comms.provision_contact(user.id, agent.id, %{
          "prompt_from_number" => "+15550001111"
        })

      {:ok, _} =
        Fountain.Team.Comms.update_contact(user.id, agent.id, %{
          "prompt_from_number" => "+15550002222"
        })
    end)
  end

  def do_contact_opt_out(user) do
    with_comms(user, fn agent ->
      {:ok, c} =
        Fountain.Team.Comms.provision_contact(user.id, agent.id, %{
          "prompt_from_number" => "+15550001111"
        })

      {:ok, _} = Fountain.Team.Comms.set_opt_out(c, true)
    end)
  end

  def do_contact_opt_in(user) do
    with_comms(user, fn agent ->
      {:ok, c} =
        Fountain.Team.Comms.provision_contact(user.id, agent.id, %{
          "prompt_from_number" => "+15550001111"
        })

      {:ok, _} = Fountain.Team.Comms.set_opt_out(c, false)
    end)
  end

  def do_contact_release(user) do
    with_comms(user, fn agent ->
      {:ok, _} =
        Fountain.Team.Comms.provision_contact(user.id, agent.id, %{
          "prompt_from_number" => "+15550001111"
        })

      :ok = Fountain.Team.Comms.release_contact(user.id, agent.id)
    end)
  end

  def do_schedule_create(user), do: insert_schedule(user)

  def do_schedule_update(user),
    do:
      {:ok, _} =
        Fountain.Team.Schedules.update_schedule(insert_schedule(user), %{"cron" => "@hourly"})

  def do_schedule_delete(user),
    do: {:ok, _} = Fountain.Team.Schedules.delete_schedule(insert_schedule(user))

  def do_schedule_run(user) do
    # Off the team, so the in-thread run fails fast — the firing is what
    # must be recorded, however it went.
    {:error, :not_found} = Fountain.Team.Schedules.run_schedule(insert_schedule(user))
  end

  def do_role_change(user), do: {:ok, _} = Fountain.Accounts.update_user_role(user, "admin")

  def do_limit_change(user), do: {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, 9)

  def do_suspend(user), do: {:ok, _, _} = Fountain.Accounts.suspend_user(user)

  def do_unsuspend(user) do
    {:ok, suspended, _} = Fountain.Accounts.suspend_user(user)
    {:ok, _} = Fountain.Accounts.unsuspend_user(suspended)
  end

  defp dek!(user_id) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)
    dek
  end

  def do_env_secret_write(user) do
    env = insert_env(user_id: user.id)
    {:ok, _} = Environments.upsert_secret(env, %{"key" => "K", "value" => "v"}, dek!(user.id))
  end

  def do_env_secret_delete(user) do
    env = insert_env(user_id: user.id)
    secret = insert_secret(env, %{"key" => "GONE"})
    {:ok, _} = Environments.delete_secret(env, secret)
  end

  def do_vault_secret_write(user) do
    vault = insert_vault(user_id: user.id)
    {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v"}, dek!(user.id))
  end

  def do_vault_secret_update(user) do
    vault = insert_vault(user_id: user.id)
    secret = insert_vault_secret(vault, key: "TOKEN")

    {:ok, _} =
      Vaults.update_secret_metadata(vault, secret.key, %{"expires_at" => "2027-01-15T00:00:00Z"})
  end

  def do_vault_secret_delete(user) do
    vault = insert_vault(user_id: user.id)
    secret = insert_vault_secret(vault, %{"key" => "GONE"})
    {:ok, _} = Vaults.delete_secret(vault, secret)
  end

  def do_password_reset(user), do: {:ok, _} = Fountain.Accounts.reset_password(user, "newpass123")

  def do_password_change(user) do
    {:ok, _} = Fountain.Accounts.change_password(user, "password123", "newpass123")
  end

  def do_verify_email(user), do: {:ok, _} = Fountain.Accounts.verify_email(user)

  def do_credit_grant(user) do
    {:ok, _} =
      Fountain.Credits.grant(user.id, 100, "grant_admin", idempotency_key: "guard-#{user.id}")
  end

  def do_credit_debit(user) do
    {:ok, _} =
      Fountain.Credits.debit(user.id, 1, "burn_turn", idempotency_key: "guard-b-#{user.id}")
  end

  # The consent request the test client in config/test.exs accepts.
  defp oauth_request do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %{
      "client_id" => "test-app",
      "redirect_uri" => "https://app.test/callback",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      "code_challenge_method" => "S256"
    }
  end

  def do_oauth_authorize(user), do: {:ok, _} = Fountain.OAuth.authorize(user.id, oauth_request())

  def do_oauth_client_create(user) do
    {:ok, _} = OAuth.create_client(user.id, oauth_client_attrs())
  end

  def do_oauth_client_update(user) do
    {:ok, _} = OAuth.update_client(insert_oauth_client(user_id: user.id), %{"name" => "renamed"})
  end

  def do_oauth_client_delete(user) do
    {:ok, _} = OAuth.delete_client(insert_oauth_client(user_id: user.id))
  end

  def do_oauth_device_approve(user) do
    {:ok, %{user_code: code}} = Fountain.OAuth.start_device_grant()
    :ok = Fountain.OAuth.approve_device_grant(code, user.id)
  end

  def do_oauth_device_deny(user) do
    {:ok, %{user_code: code}} = Fountain.OAuth.start_device_grant()
    :ok = Fountain.OAuth.deny_device_grant(code, user.id)
  end

  # ── claimable principals (ADR 0044) ──────────────────────────────────────

  def do_claimable_create(app) do
    {:ok, _} = Principals.create_claimable(app, %{"application_id" => "guardrail"})
  end

  def do_claimable_claim(app) do
    {:ok, %{claimable: c, claim_token: token}} =
      Principals.create_claimable(app, %{"application_id" => "guardrail"})

    {:ok, _} = Principals.claim(c.id, token, insert_verified_user())
  end

  def do_claimable_release(app) do
    {:ok, %{claimable: c}} = Principals.create_claimable(app, %{"application_id" => "guardrail"})
    {:ok, _} = Principals.release(c)
  end
end
