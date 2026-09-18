defmodule Fountain.Conversations.FreshProvision do
  @moduledoc """
  Building a machine for a conversation that has none: the fresh arm of
  `ConversationServer`'s `handle_continue(:provision)`.

  Lifted out of that server in ADR 0058 stage 7b, which is the move #1369 asks
  for and the stage that made it worth making. The arm had two halves tangled
  together — *who owns the machine* (the status writes, the create, the
  destroys on the failure paths) and *what goes on the disk* (skills, a runtime
  config, an env file, a broker CA, packages, a clone, a setup script, an
  inference reservation, an adapter) — and stage 7b separates them. The first
  half is `Fountain.Machines.Provision`, the owner's bracket. The second is
  `pipeline/3` below, which the bracket runs as a callback, and which is the
  same sequence of steps it has always been.

  So this module is the seam between them: it assembles what the pipeline
  needs from the server's state, hands the bracket a closure over it, and
  turns the bracket's answer back into the `handle_continue` reply the server
  owes OTP. The state it builds and the adapter it ends at are still the
  server's (ADR 0037) — every function here takes that state and gives it
  back.

  `ConversationServer.reattach/6` is the other arm and stays where it is: it
  works on a machine that already exists, so it has no bracket around it, only
  the two owner calls at its end.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.ActorStatus
  alias Fountain.Conversations.{Checkpoints, ConversationServer, Egress, Lifecycle, Output}
  alias Fountain.Conversations.{Provisioning, ProvisionWatchdog, Reapply, TurnMachine}
  alias Fountain.Machines.Machine

  # The two answers from a provision's pipeline that mean another actor already
  # owns this row: a reapply or a reassignment that committed while the provider
  # was working, and a reset fence that landed in the same window. The machine
  # this attempt built is destroyed by the protocol; the conversation is left
  # alone, because a successor owns it. `Fountain.Machines.Provision` keeps the
  # same list for the row's half of the decision.
  @foreign_provision_owner [:configuration_changed, :sandbox_reset_pending]

  @doc """
  Provision a machine for `conv` and answer `handle_continue(:provision)`.
  """
  @spec run(map(), map(), map(), map() | nil, map() | nil, map()) ::
          {:noreply, map()} | {:stop, :normal, map()}
  def run(state, conv, sandbox, agent, env, secrets) do
    Fountain.Telemetry.span(
      [:fresh_provision],
      %{conv_id: state.conversation_id, sandbox_id: sandbox.id, env_id: env && env.id},
      fn -> {do_run(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  defp do_run(state, conv, sandbox, agent, env, secrets) do
    try do
      do_run_inner(state, conv, sandbox, agent, env, secrets)
    rescue
      exception ->
        stack = __STACKTRACE__
        msg = Exception.format(:error, exception, stack)
        Logger.error("provision raised an unhandled exception:\n#{msg}")

        ConversationServer.fail_machine(sandbox.id, :provision_raised, conv.id)

        ActorStatus.fail(state, %{
          reason: Exception.message(exception),
          stack: Exception.format_stacktrace(stack) |> String.slice(0, 2000)
        })

        {:stop, :normal, state}
    end
  end

  defp do_run_inner(state, conv, sandbox, agent, env, secrets) do
    skills = (agent && agent.skills) || []
    # conv.runtime is validated-required and outlives the agent; the agent
    # fallback covers rows predating it. The mount logs what it skipped.
    runtime = conv.runtime || (agent && agent.runtime) || "claude"

    ctx = %{
      state: state,
      conv: conv,
      sandbox: sandbox,
      agent: agent,
      env: env,
      secrets: secrets,
      skills: skills,
      runtime: runtime
    }

    provision_machine(ctx)
  end

  # What this server does once the machine is its own and the intent is on the
  # row, and before anything is created. `Machines.Provision` runs it for that
  # reason: a row retirement won while this server was starting never reaches
  # here, so it announces nothing.
  #
  # `interrupted?` is the protocol's reading, not a guess from the snapshot this
  # server read before it claimed anything — an earlier attempt that died
  # between stamping its intent and creating its machine is a rebuild too, and
  # only the row under the lease knows.
  defp announce_and_check(state, sandbox, env, interrupted?) do
    Output.publish_stage(
      state.conversation_id,
      "provision",
      "started",
      if(interrupted?,
        do: %{retry: "an earlier attempt was interrupted; rebuilding the sandbox"},
        else: %{}
      )
    )

    check_provider_pairing(state, sandbox, env)
  end

  # A `limited` environment on a backend with no `:network_policy` capability
  # can only fail. It failed closed before, but several steps in, after a
  # sandbox had been created and torn down, and wearing the shape of a
  # transport error. Refuse the pairing here, by name, before anything is
  # provisioned (#935).
  defp check_provider_pairing(state, sandbox, env) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    with :ok <-
           Provisioning.check_network_policy_support(provider, env, state.conversation_id) do
      Provisioning.check_broker_support(
        Egress.brokered?(),
        provider,
        env,
        state.conversation_id
      )
    end
  end

  # The bracket (ADR 0058 stage 7b). The owner claims the machine's lease,
  # stamps the intent, creates the machine, runs `provision_pipeline/3` under a
  # renewed lease and writes `ready` or `failed` from what it answers. Every
  # step of the pipeline, and the adapter it ends at, stay in this server
  # (ADR 0037, #1369).
  defp provision_machine(ctx) do
    %{state: state, conv: conv, sandbox: sandbox, env: env, skills: skills} = ctx

    result =
      Machine.provision(
        sandbox.id,
        &pipeline(ctx, &1, &2),
        actor: "system:conversation_server",
        conversation_id: conv.id,
        on_claim: &announce_and_check(state, sandbox, env, &1),
        # Known before the pipeline runs, both of them, because they describe
        # what the disk is *to be* built from rather than anything the build
        # discovers. Written by the finalize, in the statement that makes the
        # row `ready`.
        ready_attrs: [build_fingerprint: Reapply.fingerprint(env), applied_skills: skills],
        # The lease is renewed for as long as this server's own ceiling on
        # provisioning allows, and no longer: past it the renewals stop, the
        # lease lapses, and `ProvisionWatchdog` is what retires the row.
        deadline_ms: ProvisionWatchdog.deadline_ms()
      )

    case result do
      {:ok, :provisioned, %{state: provisioned, conv: conv, handle: handle}} ->
        Output.publish_stage(state.conversation_id, "provision", "done")

        # Best-effort: snapshot the fully-provisioned state so subsequent
        # conversations on this env can warm-start from it. Async so it
        # doesn't block the user's first turn, and outside the bracket for the
        # same reason — a lease held across a disk upload answers 503 to every
        # prompt that arrives during it.
        Checkpoints.maybe_create_async(handle, env)

        # Any prompt this conversation was started for arrives as a cast,
        # already queued behind this handle_continue. See
        # queue_initial_prompt/3.
        {:noreply, TurnMachine.forget_runtime_session(provisioned, conv)}

      # Retirement won, or another server holds this machine, and this attempt
      # never got as far as preparing anything — the protocol says so by
      # answering without a result. Leave the winner and any replacement
      # conversation alone, and announce nothing.
      #
      # **Which outcomes reach here is the protocol's statement, not a guess**
      # (round 1, behaviour review). The first draft read this arm as "before
      # the pipeline ran" and the sibling below as "after", and one outcome
      # broke that reading: a supersession the *renewer* detected returned a
      # bare two-tuple although `fun` had run to completion, so the broker
      # session and the callback key the pipeline had just minted were left
      # live. `Renewal.around/5` carries its result now, so the shape of the
      # answer and the existence of a state to unwind are the same fact.
      {:ok, settled} when settled in [:already_terminal, :claimed_elsewhere] ->
        {:stop, :normal, state}

      # The same two, carrying what the pipeline reached — the row was retired,
      # or the lease taken over, while the provider was working. The machine is
      # the protocol's to destroy and has been; what is left for this server is
      # the session and the key its pipeline minted, which belong to the attempt
      # rather than to the machine.
      {:ok, settled, %{state: reached}} when settled in [:already_terminal, :claimed_elsewhere] ->
        Egress.release_prepared({:ok, reached})
        {:stop, :normal, reached}

      # Another actor owns the row: a reapply that committed, or a reset fence,
      # either detected by a pipeline step or by the finalize. Same treatment —
      # the conversation is a successor's, and this attempt unwinds its own.
      {:error, reason, %{state: reached}} when reason in @foreign_provision_owner ->
        Egress.release_prepared({:ok, reached})
        {:stop, :normal, reached}

      {:error, reason, %{state: reached}} ->
        Egress.release_prepared({:ok, reached})
        announce_failed_provision(reached, conv, reason)

      {:error, :sandbox_reset_pending} ->
        {:stop, :normal, state}

      {:error, reason} ->
        provision_could_not_start(state, conv, sandbox, reason)
    end
  end

  # The machine never existed: the pairing check refused it, or the provider
  # would not create it. The row is the protocol's to fail where it claimed
  # one, and this server's where it never got that far.
  defp provision_could_not_start(state, conv, sandbox, reason) do
    Logger.error("provision could not start: #{inspect(reason)}")
    ConversationServer.fail_machine(sandbox.id, :provision_could_not_start, conv.id)
    announce_failed_provision(state, conv, reason)
  end

  defp announce_failed_provision(state, _conv, reason) do
    ActorStatus.fail(state, %{reason: inspect(reason)})
    {:stop, :normal, state}
  end

  # Every step between the machine existing and the row saying `ready`:
  # unchanged from `main` but for its two ends. It is handed a machine rather
  # than creating one, and it answers rather than writing the row — so the
  # `ready` claim that used to sit inside this `with` is the protocol's
  # finalize, and the three `Managoat.Sandbox.destroy/1` calls that used to sit
  # in its `else` are the protocol's failure arms.
  #
  # `epoch` is the lease this provision holds. One step records something on the
  # row mid-provision — the machine's public URL — and writes it by
  # compare-and-set on that epoch, so a superseded attempt leaves no URL behind.
  defp pipeline(ctx, handle, epoch) do
    %{state: state, conv: conv, sandbox: sandbox, agent: agent, env: env} = ctx
    %{secrets: secrets, skills: skills, runtime: runtime} = ctx

    Fountain.SandboxSkills.mount(handle, runtime, skills)

    {state, conv} = ConversationServer.rotate_callback_api_key(state, conv)

    # Looked up once, here, because it is stable for the sandbox's life and
    # the agent needs it in its environment before the first turn runs.
    sandbox_url = Provisioning.record_sandbox_url(sandbox, handle, epoch)

    # The broker session is minted before the env is built, because the
    # env carries it; the CA is installed before anything dials out,
    # because nothing dials out without it (ADR 0019 gate 1a).
    # Keep the result outside `with`: its else cannot see the minted state.
    prepared = Egress.prepare_state(state)

    with {:ok, state} <- prepared,
         sprite_env = ConversationServer.build_sprite_env(state, agent, env, secrets, sandbox_url),
         # A real step, not best effort: an agent whose MCP servers could
         # not be written would otherwise run without them and report
         # `provision/done`. The runtimes retry the write themselves.
         :ok <-
           Provisioning.write_runtime_config(
             handle,
             state.runtime_module,
             Egress.with_connection_servers(
               agent,
               state.user_id,
               state.conversation_id,
               state.callback_token
             )
           ),
         _ = Provisioning.write_instructions(handle, runtime, agent),
         # The file is the machine's; the conversation's identity travels as
         # process env on every spawn (`Fountain.Conversations.Identity`).
         :ok <-
           Provisioning.write_env_file(
             handle,
             Fountain.Conversations.Identity.disk_env(sprite_env)
           ),
         :ok <- Egress.install_ca(state.broker, handle, state.conversation_id),
         :ok <-
           run_provisioning_pipeline(
             handle,
             env,
             sprite_env,
             secrets,
             state.conversation_id,
             Egress.brokered?()
           ),
         :ok <- Fountain.Conversations.InferenceBinding.reserve(conv, state.inference_source),
         :ok <-
           Provisioning.prepare_runtime_sprite(
             handle,
             runtime,
             state.runtime_module,
             agent,
             sprite_env
           ) do
      {:ok,
       %{
         conv: conv,
         handle: handle,
         state: %{
           state
           | handle: handle,
             sprite_env: sprite_env,
             # Dated from the sandbox row, not from now, so the absolute
             # lifetime ceiling survives a restart and a reattach rather than
             # resetting.
             sandbox_started_at: Lifecycle.clock_start(sandbox)
         }
       }}
    else
      {:error, reason} ->
        # The state this attempt reached travels with the error; releasing it is
        # `run/6`'s, because the row may also be lost *after* this returns —
        # retired or taken over at the finalize — and one place that unwinds an
        # attempt is better than two that have to agree.
        {:error, reason, %{state: reached_state(prepared, state)}}
    end
  end

  # The state a failed pipeline stops with: the one carrying the broker session
  # if it got that far, so `terminate/2` sees what this attempt actually held.
  defp reached_state({:ok, prepared_state}, _state), do: prepared_state
  defp reached_state(_unprepared, state), do: state

  # Try a checkpoint restore first if the env has one. If restore succeeds,
  # skip the slow steps (packages + clone + setup_script) — they all wrote to
  # the disk the checkpoint captured, so restoring it restores their effect.
  # If restore fails, clear the checkpoint id and fall through to the full
  # pipeline.
  #
  # The network policy is **not** one of those steps and is applied on both
  # arms (#989). It is configuration on the sandbox, not a file: a warm start
  # creates a fresh sandbox and pours a disk image into it, and that sandbox
  # carries no policy. Skipping it turned a `limited` environment into an
  # unrestricted one, silently, and reported `provision/done`. It costs one
  # fast API call, so the warm start pays nothing for it.
  defp run_provisioning_pipeline(handle, env, sprite_env, secrets, conv_id, brokered?) do
    case Checkpoints.attempt_warm_start(handle, env, conv_id) do
      :warm_started ->
        Egress.apply_policy(handle, env, conv_id, brokered?)

      :cold ->
        with :ok <-
               Fountain.Conversations.Provisioning.install_packages(
                 handle,
                 env,
                 sprite_env,
                 conv_id
               ),
             :ok <- Egress.apply_policy(handle, env, conv_id, brokered?),
             :ok <-
               Fountain.Conversations.Provisioning.clone_repositories(
                 handle,
                 env,
                 secrets,
                 sprite_env,
                 conv_id
               ) do
          Provisioning.run_setup_script(handle, env, sprite_env, conv_id)
        end
    end
  end
end
