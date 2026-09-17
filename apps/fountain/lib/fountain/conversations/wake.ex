defmodule Fountain.Conversations.Wake do
  @moduledoc """
  Waking a conversation: deciding what a stored sandbox can still do, and
  bringing a `ConversationServer` up on it, including the fresh-sandbox path
  and moving co-tenants off a dead machine (#2211).

  `wake_conversation/2` (delegated from `Fountain.Conversations`) is the
  request-facing door for a fresh prompt; `Conversations.wake_for_interrupt/1`
  is the door for an interrupt. Both establish tenant ownership of `conv_id`
  before calling `wake_conversation_for/3` here, and every `sandbox_id` this
  module reads comes from that already-scoped conversation row, so leaves are
  documented as relying on that ownership rather than re-justifying it on
  their own.

  The two purposes diverge on a dead or stranded sandbox — a probe that
  answers `:create_new`, or a `pending`/`starting` row whose server never
  turns up before the registry-settle wait gives up: `:work` still
  provisions a fresh one either way, but `:interrupt` never does (decided
  2026-09-15, #2175 open decision 1) — there is no turn a new sprite could
  continue, so it reconciles the orphaned row instead of paying for compute
  nothing will use (`reconcile_dead_interrupt/1`, fenced to the sandbox this
  wake actually probed).
  """

  import Ecto.Query

  require Logger

  alias Fountain.Agents
  alias Fountain.Conversations

  alias Fountain.Conversations.{
    Conversation,
    ConversationServer,
    Launch,
    MachineEvents,
    Reattachment,
    Sandbox,
    Termination
  }

  alias Fountain.Machines.Machine
  alias Fountain.Repo

  # Where a sandbox stops. A terminal row is never a machine an owner is still
  # working on, whatever its lease or transition says.
  @terminal_statuses ~w(terminated failed)

  # Probe the existing sandbox: if it's `ready` or `suspended` and sprites.dev
  # confirms the sprite still exists, we can reattach without provisioning a
  # new one. Otherwise, fall through to creating a fresh sandbox.
  #
  # The leaf `wake_conversation_for/3` calls first, once ownership is
  # established there; `sandbox_id` is the conversation's own row.
  def maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  def maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{reset_requested_at: at, status: status}
      when not is_nil(at) and status not in @terminal_statuses ->
        {:error, :sandbox_reset_pending}

      # An owner holds a live lease on this machine (ADR 0058 stage 6a).
      # Refused *before* the probe, so a machine somebody is destroying — or,
      # from 6b, parking — gets no provider call from this wake, and refused
      # with the word the whole system already has for "not right now": 503
      # with a `Retry-After: 30`, which is honest because the operation is
      # live and one provider round trip from settling.
      #
      # A stamped `transition` on a lease-less row is *not* refused, and that
      # is the round-1 correction: such a row is an owner that died
      # mid-operation, which the reaper's own fenced-teardown sweep calls
      # abandoned, and refusing it kept a caller from the fresh machine `main`
      # would have given it for as long as an hour. `Machine.busy?/2` says why.
      #
      # After the reset fence, deliberately. A reset that the owner refused
      # leaves `transition: "destroying"` on a live row with its lease
      # released (stage 5c), and `:sandbox_reset_pending` is the precise
      # answer there: the fence is in place, the reconciler will finish it,
      # and a retry of the reset is 409 rather than "try again in 30s".
      # The more specific word wins by being asked first.
      #
      # Before the status clauses, and only for a non-terminal row. A finalize
      # writes `terminated` and releases the lease as two statements, so a
      # terminal row with a live lease is a real momentary state and it means
      # the machine is gone — which is `:create_new` below, not a retry.
      # A provision in flight, **before** the mid-operation check and not
      # refused by it (ADR 0058 stage 7b). A `pending` or `starting` row now
      # carries a live lease for the length of the provision — that is what the
      # bracket is — and refusing it here would answer 503 to the ordinary
      # `session/new` followed by a prompt 30ms later, which is the exact shape
      # #800 closed by waiting for the registry instead. The answer a machine
      # being *built* owes a second caller is "wait for the server", not "try
      # again in thirty seconds"; the answer a machine being destroyed or
      # parked owes one is the other way round, and those rows are below.
      %Sandbox{status: status} when status in ["pending", "starting"] ->
        {:provisioning, sandbox_id}

      %Sandbox{status: status} = sandbox when status not in @terminal_statuses ->
        if Machine.busy?(sandbox),
          do: {:error, :sandbox_unavailable},
          else: classify_reusable(sandbox, sandbox_id)

      _ ->
        :create_new
    end
  end

  # The reuse verdict for a machine no owner is working on. Split out of
  # `maybe_reuse_sandbox/1` when the mid-operation check went in front of it,
  # so there is one place that check cannot be skipped.
  #
  # It had a `pending`/`starting` clause until stage 7b, which answered
  # `{:provisioning, sandbox_id}`. That answer moved *above* the busy check in
  # `maybe_reuse_sandbox/1` — a provision holds a lease for its whole length now,
  # and a row being built owes a second caller "wait for the server" rather than
  # "try again in thirty seconds" — so nothing reached the clause any more.
  defp classify_reusable(%{status: status, machine_name: name} = sandbox, sandbox_id)
       when status in ["ready", "suspended"] and is_binary(name),
       do: probe_reusable_sandbox(sandbox, sandbox_id)

  defp classify_reusable(_sandbox, _sandbox_id), do: :create_new

  # The row's provider is sticky: a parked sandbox wakes on the backend that
  # holds its disk, never on whatever the instance default is by now. A row
  # whose (non-default) provider lost its credentials fails retryably — the
  # same protect-the-parked-disk reasoning as :sprite_probe_failed below;
  # falling through to :create_new would retire the row and orphan (or lose)
  # the parked sandbox. Re-adding the credentials restores wakes.
  #
  # A leaf of maybe_reuse_sandbox/1.
  def probe_reusable_sandbox(%{status: status, machine_name: name} = sandbox, sandbox_id) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    if provider != Fountain.SandboxProviders.default_provider() and
         not Fountain.SandboxProviders.enabled?(provider) do
      Logger.warning(
        "sandbox #{sandbox_id} is on disabled provider #{provider}; refusing to wake or retire"
      )

      {:error, {:sandbox_provider_disabled, provider}}
    else
      probe_sandbox(provider, name, status, sandbox_id)
    end
  end

  # A leaf of probe_reusable_sandbox/2.
  #
  # **The probe reports what the machine says about itself, not only that it
  # answered** (ADR 0058 stage 7a). Until 7a any `{:ok, _info}` was a reuse,
  # whatever `info.status` said, and the 6b review named what that cost: a park
  # whose finalize was lost leaves a row saying `ready` over a machine the
  # provider has genuinely stopped, and on E2B (`paused`) and Daytona
  # (`stopped`/`archived`) the wake then handed a conversation a handle to a
  # machine that was not running. The third element of the verdict is
  # `Managoat.Sandbox`'s own three-value fold — `:running | :suspended |
  # :unknown` — and `Machines.Resume` is what acts on it.
  #
  # Per adapter, so nobody has to go and find out:
  #
  #   * **E2B** and **Daytona** report it faithfully. E2B's lookup asks for
  #     `running,paused` explicitly and folds `paused` to `:suspended`; Daytona
  #     folds six parked states including `archived` the same way. These are the
  #     two the gap was real on.
  #   * The **self-hosted runner** reports it faithfully too, from the suspend
  #     marker its daemon writes (process backend) or the VM's own control
  #     socket (Firecracker).
  #   * **Sprites** cannot, and does not need to. Its `suspend/1` is a
  #     documented no-op — the sprite scales to zero on the platform's schedule —
  #     so `get/1` reports that schedule rather than anything Fountain did, and
  #     its `resume/1` is a probe: a sprite reported `stopped` here is resumed by
  #     the next exec whatever this says. The residual on Sprites is therefore
  #     not a missed wake but a `sandbox.resumed` event and a
  #     `last_resumed_at` stamp on a machine that had scaled to zero by itself,
  #     which is a fair description of what happened.
  #   * `:unknown` — a body without a status this adapter recognises — is
  #     treated as running, i.e. as `main` treated every answer. Resuming on a
  #     guess is the write that claims more, and this is the guess.
  def probe_sandbox(provider, name, status, sandbox_id) do
    case Managoat.Sandbox.get(Managoat.Sandbox.build_handle(provider, name)) do
      {:ok, info} ->
        {:reuse, sandbox_id, Map.get(info, :status, :unknown)}

      {:error, :not_found} ->
        :create_new

      # The machine behind a runner-backed sandbox is not connected (#834):
      # the same protect-the-disk rule as below, named, so the caller can say
      # "the machine is off" rather than "the provider is unreachable".
      {:error, {:unavailable, :runner_offline}} ->
        {:error, :runner_offline}

      {:error, reason} ->
        # A transient probe failure must not cost the disk: falling to
        # :create_new retires this row, and the reaper then destroys the
        # still-live sprite — with the agent's memory on it. Only a
        # definitive not-found gives up the sandbox; anything else fails the
        # wake retryably (503 + Retry-After at the API).
        #
        # This clause was `suspended`-only until #799: a `ready` row is the
        # same parked disk once its server is gone (a deploy, a crash, a
        # partition), and the 2026-08-18 incident showed the provider going
        # unreachable for 70 s with nine `ready` rows behind it.
        Logger.warning(
          "sprite probe failed for #{status} sandbox #{sandbox_id}: #{inspect(reason)}"
        )

        {:error, :sprite_probe_failed}
    end
  end

  @doc """
  Make sure the conversation's machine is up, through its owner (ADR 0058
  stage 7a).

  One call to `Fountain.Machines.Machine.ensure_up/2`, which does everything
  this function used to do itself and one thing it could not. What it used to
  do: re-read the row, ask the provider to resume a `suspended` one, write
  `ready` and stamp `last_resumed_at`, and re-run the quota gate — because a
  parked sprite is not compute (ADR 0017) and waking one is. What it could not:
  make two prompts arriving on one parked home resume it **once**. Both read
  `suspended`, both called the provider, both wrote `ready`; the only thing
  between them was the per-*user* advisory lock the quota reservation happens to
  hold, which serialized two wakes of two different machines that had no need to
  be serialized and ran a provider round trip inside a database transaction
  doing it.

  The owner's lease is per machine, so the second wake waits for the first and
  then finds the machine already up; and the quota checks now commit before the
  provider is called rather than around it. `Fountain.Machines.Resume` is where
  that ordering is argued.

  Asked unconditionally, on every reuse: `ensure_up/2` answers
  `{:ok, :already_up}` for a `ready` row without calling anybody, which is what
  the status check here used to buy and what makes the name honest.

  The second leaf `wake_conversation_for/3` calls, once ownership is
  established there; `conv` is the caller's own tenant-scoped row and
  `sandbox_id` is that conversation's own machine.
  """
  def wake_suspended_sandbox(%Conversation{} = conv, sandbox_id, observed \\ :unknown)
      when is_binary(sandbox_id) do
    Machine.ensure_up(sandbox_id,
      # ADR 0013: the work is done by this module on an unattended path — the
      # prompt that triggered it is the conversation's, not an operator's, and
      # the conversation is recorded in the event's metadata instead.
      actor: "system:wake",
      requesting_conversation_id: conv.id,
      observed: observed
    )
  end

  # The child spec deliberately carries no prompt.
  #
  # Horde redistributes children when cluster membership changes — which every
  # deploy does — and restarts each one from its *stored child spec*. A prompt
  # baked into that spec is therefore replayed on every rebalance, silently
  # re-running the user's last message against the agent. Production
  # accumulated 38 turns from 2 distinct prompts on one conversation this way,
  # one duplicate per rollout, and the agent on the other end spent several
  # turns pointing out it was being asked the same thing repeatedly.
  #
  # So the prompt is delivered out of band, after the server exists. A cast is
  # queued behind handle_continue(:provision), so it is processed once
  # provisioning finishes; if provisioning fails the server stops and the cast
  # dies with it, which is the right outcome — no turn on a failed provision.
  #
  # The third leaf `wake_conversation_for/3` calls on the reuse path; also
  # called from `create_fresh_sandbox_and_start/4` below on the fresh-sandbox
  # path. `conv` is the caller's own tenant-scoped row, so the re-fetch below
  # reads under that same ownership.
  def start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
    # Through the one registration door (ADR 0058 stage 6a): it stamps the
    # sandbox's `woken_at` marker under the per-sandbox lock before Horde is
    # asked for anything, so a reaper on another node sees this wake as a
    # database fact rather than waiting on registry propagation (#2307
    # constraint 4). It hands Horde's answer back verbatim, so the
    # `{:already_started, winner_pid}` both call sites of this function
    # compensate for still arrives unchanged.
    with {:ok, pid} <-
           Conversations.register_server(
             sandbox_id,
             Launch.child_spec(conv.id, sandbox_id, runtime_module)
           ) do
      if is_binary(initial_prompt) and initial_prompt != "" do
        ConversationServer.queue_initial_prompt(pid, initial_prompt)
      end

      # ownership: conv is the caller's own tenant-scoped row (see the
      # function doc above); this re-fetch reads under that same ownership.
      {:ok, Conversations._unsafe_get_conversation!(conv.id)}
    end
  end

  @doc """
  Resume a conversation whose ConversationServer is gone (e.g. after a
  BEAM restart, or in the gap between Rehydrator runs).

  Strategy:
  1. If the existing sandbox is `ready` and the sprite is still alive at
     sprites.dev, start a fresh `ConversationServer` pointing at it. The
     server will go through reattach mode and pick up any running
     detachable session.
  2. Otherwise, provision a fresh sprite, mark the old sandbox
     terminated, and start the server pointing at the new sandbox. The
     runtime session does not follow — it lived on the old disk — so the
     server clears `runtime_session_id` once the fresh sprite is up and the
     next turn starts a new one (#778). The Fountain conversation, its
     transcript and its title carry over; the agent's in-context memory
     does not.

  Returns `{:error, :gone}` if the conversation is in a terminal status
  (`terminated`, `failed`) — those don't auto-resume.
  """
  def wake_conversation(conv_id, initial_prompt \\ nil) do
    wake_conversation_for(conv_id, initial_prompt, :work)
  end

  # Not a request-facing entry point. `wake_conversation/2` above is the door
  # for a fresh prompt, and `Conversations.wake_for_interrupt/1` (still in
  # `Conversations` until stage 4, #2213) is the door for an interrupt; both
  # establish tenant ownership of `conv_id` before calling here. The
  # `_unsafe_get_conversation` read just below relies on that caller-scoped
  # fetch, not on any check of its own — add no further public entry.
  def wake_conversation_for(conv_id, initial_prompt, purpose) do
    # Ownership is established by callers before reaching this internal wake
    # path. The agent fetched below is the conversation's own agent_id,
    # same tenant by construction.
    with :ok <- Conversations.require_provider_commit_boundary(),
         %Conversation{} = conv <-
           Conversations._unsafe_get_conversation(conv_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         # Preflight only: no database lock spans provider I/O. Turn admission
         # checks again under its transaction. Cancellation must remain
         # reachable. ownership: conv fetched above is already tenant-scoped.
         :ok <-
           if(purpose == :interrupt,
             do: :ok,
             else: Conversations._unsafe_check_saved_execution_allowance(conv.id)
           ),
         # Ownership: conv.agent_id belongs to this established-owner conversation.
         %Agents.Agent{} = agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:error, :no_agent},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(conv) do
      case maybe_reuse_sandbox(conv) do
        {:reuse, sandbox_id, observed} ->
          # Reuse provisions nothing, so the fresh-path gates below never ran
          # here — a canceled or suspended user could restart a server against
          # a live sprite and keep prompting (#313). Same checks. Reusing a
          # `ready` machine adds no concurrency, so no quota; bringing a parked
          # one back re-adds compute, so `wake_suspended_sandbox/3` runs the
          # quota gate inside the owner's admission. The per-turn gate in
          # ConversationServer is the backstop; this one makes the refusal
          # synchronous at the API door.
          #
          # `observed` is what the probe just heard from the provider, carried
          # in so the owner can wake a machine the row calls `ready` and the
          # provider calls stopped — see `probe_sandbox/4`.
          with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
               :ok <- Fountain.Billing.check_spend(conv.user_id),
               :ok <- check_saved_inference(conv, agent),
               {:ok, _} <- wake_suspended_sandbox(conv, sandbox_id, observed) do
            case start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
              {:error, {:already_started, winner_pid}} ->
                # Lost a concurrent wake of the same conversation to another
                # caller reusing the same sandbox. Mirrors the handoff in
                # create_fresh_sandbox_and_start/4 (#330), but reuse provisions
                # no row of its own, so there is nothing here to clean up —
                # just hand the prompt to the winner, which drops it if a turn
                # is already running.
                if is_binary(initial_prompt) and initial_prompt != "" do
                  ConversationServer.queue_initial_prompt(winner_pid, initial_prompt)
                end

                # ownership: conv established tenant-scoped above; this
                # re-fetch reads under that same ownership.
                {:ok, Conversations._unsafe_get_conversation!(conv.id)}

              other ->
                other
            end
          end

        {:provisioning, sandbox_id} ->
          # The row says a server is (or was) provisioning this sandbox. The
          # registry may simply not have caught up with a server started on
          # another node — `session/new` and the first prompt arrive ~30 ms
          # apart and can land on different pods — so wait for it before
          # concluding it is dead. If it turns up, hand it the prompt exactly
          # as the `already_started` branches do; if it does not, the
          # provision died with its BEAM and a fresh one is right (#800).
          case ConversationServer.await_registered(conv.id) do
            {:ok, pid} ->
              Logger.info(
                "conv #{conv.id}: server for pending sandbox #{sandbox_id} " <>
                  "appeared during the registry settle window; handing off the prompt"
              )

              if is_binary(initial_prompt) and initial_prompt != "" do
                ConversationServer.queue_initial_prompt(pid, initial_prompt)
              end

              # ownership: conv established tenant-scoped above; this
              # re-fetch reads under that same ownership.
              {:ok, Conversations._unsafe_get_conversation!(conv.id)}

            :timeout ->
              # The provision died with its BEAM and nothing ever came up on
              # this sandbox either. An interrupt has nothing to provision
              # for here any more than it does on a flat :create_new
              # (immediately below) — same no-provision rule, same reconcile
              # helper, same fence.
              #
              # **Unless an owner is holding the machine right now** (ADR 0058
              # stage 7b). This is the one place the registry's silence used to
              # be taken as proof of absence, and since a provision holds a
              # lease for its whole length there is now a durable answer to ask
              # instead: a live lease means a server *is* building this machine,
              # wherever the CRDT has got to, and replacing it would create a
              # second billable machine over a live one. 6a's rule, at the point
              # that decides rather than at the door — the door still waits for
              # the registry, which is what #800 fixed.
              cond do
                provisioning_owner_live?(sandbox_id) ->
                  Logger.info(
                    "conv #{conv.id}: sandbox #{sandbox_id} is being provisioned by an owner " <>
                      "the registry has not published; refusing rather than replacing it"
                  )

                  {:error, :sandbox_unavailable}

                purpose == :interrupt ->
                  reconcile_dead_interrupt(conv)

                true ->
                  create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)
              end
          end

        # An interrupt with no live server and no sandbox worth reusing has
        # nothing to provision for: there is no turn a fresh sprite could
        # continue, only a row to reconcile (Jake, 2026-09-15, #2175 open
        # decision 1). Provisioning here used to run anyway, and the
        # `:interrupt` call to the new server then queued behind
        # `handle_continue(:provision)` and timed out to `{:error,
        # :provisioning}` — a paying wake for an interrupt that could not
        # reach anything. `purpose: :work` is untouched: a prompt on a dead
        # or stranded sandbox still provisions fresh, here and in the
        # `:timeout` arm above.
        :create_new when purpose == :interrupt ->
          reconcile_dead_interrupt(conv)

        :create_new ->
          create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)

        {:error, _} = err ->
          err
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp check_saved_inference(conv, agent) do
    with {:ok, _source} <- Conversations.resolve_saved_inference(conv, agent), do: :ok
  end

  # No server, no reusable sandbox, and this wake is only for an interrupt:
  # reconcile whatever the dead incarnation left running instead of paying to
  # provision a machine nobody asked to keep working. `find_running_turn/1`
  # and `_unsafe_orphan_turn/2` are the same door the reattach path uses for
  # the same shape of loss (a turn the row still calls `running` with no
  # process left to finish it) — this is that path's decision, reached from a
  # different trigger, not a new writer of the turn or conversation row.
  #
  # The probe that produced :create_new (or the registry timeout on a
  # provisioning row) ran outside any lock, against conv.sandbox_id as read
  # before this wake started. A concurrent :work wake can rebind the
  # conversation to a replacement sandbox and admit a successor turn while
  # that probe is still in flight, so `find_running_turn/1` — reading with no
  # lock of its own — can hand back the successor's turn instead of the dead
  # incarnation's. `sandbox_id: conv.sandbox_id` fences the write to the
  # sandbox this wake actually probed: the owner's door (`Machine.end_turn/3`,
  # ADR 0058 stage 8a) re-locks the parent and rejects a changed binding as
  # `{:error, :ownership_changed}`, writing nothing. Either way this answers
  # :not_running — the interrupt was for the dead incarnation, and a successor
  # found live is somebody else's turn to finish, not this wake's to touch.
  #
  # ownership: conv is the caller's own tenant-scoped row, established by
  # wake_conversation_for/3 above.
  defp reconcile_dead_interrupt(conv) do
    case Reattachment.find_running_turn(conv.id) do
      nil ->
        :ok

      turn ->
        Machine.end_turn(turn, {:orphan, "interrupt_dead_sandbox"}, sandbox_id: conv.sandbox_id)
    end

    {:error, :not_running}
  end

  defp create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt) do
    # The sandbox being replaced is excluded: it is retired immediately below,
    # so counting it would block a wake that leaves concurrency unchanged.
    # Waking a dormant conversation provisions a fresh sprite, so it is subject
    # to the same gate as creating one. Without this, prompting an existing
    # conversation was an unmetered way past billing entirely.
    # The replacement keeps the mode of the machine it replaces: a home whose
    # sprite is gone is re-provisioned as the home, and every conversation on
    # it follows (move_cotenants/3). The old row is retired *first* for a
    # home — the partial unique index allows one live home per identity, and
    # the probe has already said this sprite is gone (ADR 0023 gate 6).
    #
    # ownership: conv is the caller's own tenant-scoped row, established by
    # wake_conversation_for/3 above; the old sandbox below is its own
    # sandbox_id.
    old = if conv.sandbox_id, do: Conversations._unsafe_get_sandbox(conv.sandbox_id)
    mode = (old && old.mode) || "ephemeral"

    with :ok <- retire_replaced_home(mode, conv.sandbox_id),
         :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
         :ok <- Fountain.Billing.check_spend(conv.user_id),
         :ok <- check_saved_inference(conv, agent),
         # A fresh sandbox is a fresh placement decision — re-resolve from
         # the agent, so a conversation whose old sandbox died can migrate
         # providers naturally.
         {:ok, provider} <- Conversations.resolve_sandbox_provider(agent),
         {:ok, machine_name} <- Conversations.mint_machine_name(provider, conv.user_id, nil),
         # Same reservation as start_conversation/1 — see the note there (#330).
         {:ok, new_sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(
             conv.user_id,
             [exclude: conv.sandbox_id],
             fn ->
               Conversations.create_sandbox(%{
                 environment_id: conv.environment_id || agent.environment_id,
                 agent_id: conv.agent_id,
                 vault_id: conv.vault_id,
                 mode: mode,
                 machine_name: machine_name,
                 status: "pending",
                 provider: Atom.to_string(provider),
                 user_id: conv.user_id
               })
             end
           ) do
      # The row is repointed *after* the server starts, not before (#717).
      #
      # The old order repointed first, so a wake that then lost the start race
      # left the conversation pointing at the sandbox it had just terminated,
      # while the winner ran on a different one — a conversation that reads as
      # terminated in the API and the UI while it is happily serving turns, and
      # an orphan `ready` row nothing references. `fountain acp` reproduced it
      # on every session, because `session/new` and the first prompt arrive a
      # second apart and the prompt takes this path before the registry has the
      # new server.
      #
      # Deferring leaves a much smaller window — between the server starting
      # and the row being updated — in which the row still names the old
      # sandbox. That one is transient and self-correcting; the old one was
      # permanent.
      #
      # #800 closed the other half: a prompt that finds a `pending` row now
      # waits for the registry (`ConversationServer.await_registered/2`)
      # before coming here, so the first server — often on another pod, and
      # so invisible to this node's registry for a beat — is found and
      # handed the prompt instead of being raced by a second provision.
      case start_conversation_server(conv, new_sandbox.id, runtime_module, initial_prompt) do
        {:ok, _} ->
          old_sandbox_id = conv.sandbox_id
          _ = mark_old_sandbox_terminated(old_sandbox_id)

          {:ok, conv} =
            Conversations.update_conversation(conv, %{
              sandbox_id: new_sandbox.id,
              status: "pending"
            })

          # The machine was gone for everyone on it, not just the conversation
          # that noticed (ADR 0023 gate 5).
          move_cotenants(old_sandbox_id, new_sandbox, conv.id)

          # ownership: conv established tenant-scoped above; this re-fetch
          # reads under that same ownership.
          {:ok, Conversations._unsafe_get_conversation!(conv.id)}

        {:error, {:already_started, winner_pid}} ->
          # Lost a concurrent wake of the same conversation. The winner's
          # server is running against its own sandbox; this one's just-created
          # row would otherwise sit pending — holding a quota slot — until the
          # reaper's pass an hour later, so a user at their cap could lock
          # themselves out by double-clicking (#330). Clean up our own row and
          # hand the prompt to the winner, which drops it if a turn is already
          # running — exactly right for a double-click.
          #
          # The conversation is left alone: the winner owns it, and it is the
          # winner's sandbox the row should name.
          _ = mark_old_sandbox_terminated(new_sandbox.id)

          if is_binary(initial_prompt) and initial_prompt != "" do
            ConversationServer.queue_initial_prompt(winner_pid, initial_prompt)
          end

          # ownership: conv established tenant-scoped above; this re-fetch
          # reads under that same ownership.
          {:ok, Conversations._unsafe_get_conversation!(conv.id)}

        {:error, _} = err ->
          # Nothing ever ran on this sandbox. Retiring it keeps a failed wake
          # from holding a quota slot until the reaper's next pass — the same
          # reasoning as the branch above.
          _ = mark_old_sandbox_terminated(new_sandbox.id)
          err
      end
    end
  end

  defp assert_resumable(%Conversation{status: s}) when s in ~w(terminated failed) do
    {:error, :gone}
  end

  defp assert_resumable(_), do: :ok

  # A wake that found the sprite gone re-provisioned a machine for the
  # conversation that woke. Every other live conversation on the old row was
  # on the same dead disk, so it follows onto the new one (ADR 0023 gate 5) —
  # the alternative leaves each co-tenant pointing at a `terminated` row and
  # provisioning yet another machine on its own next prompt, and the shared
  # disk they were sharing ends up as N disks.
  #
  # `old_sandbox_id` is the row the waking conversation *used* to name; by the
  # time this runs the waking conversation itself already names the new one,
  # so it is not among the co-tenants.
  #
  # It follows only if it declared the same identity. The replacement was
  # built from the *waking* conversation's environment and vault, so handing
  # it to a co-tenant that names a different pair would run that conversation
  # on another binding's environment files and vault material, and would make
  # the machine depend on which conversation happened to wake first
  # (#1636). One that declared something else keeps pointing at the retired
  # row instead, which its own next wake reads as `:create_new` and builds
  # from its own identity.
  #
  # Either way the disk is gone for all of them, so all of them are told. A
  # co-tenant whose server is somehow alive holds a handle to the dead sprite;
  # it is told the machine is gone, cuts any turn, and stops, so its next
  # prompt takes the wake path. `runtime_session_id` is cleared for each: a
  # fresh disk has no session to resume (#778).
  #
  # ownership: old_sandbox_id and conv_id below come from the waking
  # conversation's own tenant-scoped row (create_fresh_sandbox_and_start/4
  # above).
  defp move_cotenants(nil, _new_sandbox, _conv_id), do: :ok

  defp move_cotenants(old_sandbox_id, %Sandbox{} = new_sandbox, conv_id)
       when is_binary(old_sandbox_id) do
    case Conversations._unsafe_list_cotenants_with_identity(old_sandbox_id, conv_id) do
      [] ->
        :ok

      cotenants ->
        identity = {new_sandbox.environment_id, new_sandbox.vault_id}

        {following, on_their_own} =
          Enum.split_with(cotenants, fn {_id, env_id, vault_id} ->
            {env_id, vault_id} == identity
          end)

        follow_cotenants(Enum.map(following, &elem(&1, 0)), old_sandbox_id, new_sandbox.id)
        strand_cotenants(Enum.map(on_their_own, &elem(&1, 0)), old_sandbox_id)
        :ok
    end
  end

  defp follow_cotenants([], _old_sandbox_id, _new_sandbox_id), do: :ok

  defp follow_cotenants(ids, old_sandbox_id, new_sandbox_id) do
    message =
      "The sandbox this conversation was on is gone; it moved to a fresh one together " <>
        "with the conversations that shared it. The transcript is kept, but the agent " <>
        "starts a new session and will not remember the earlier turns."

    MachineEvents.tell_cotenants(ids, old_sandbox_id, "replaced", "sprite_gone", message)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(c in Conversation, where: c.id in ^ids),
      set: [sandbox_id: new_sandbox_id, runtime_session_id: nil, updated_at: now]
    )

    Enum.each(ids, fn id ->
      Conversations.publish_stage(id, "sandbox", "done", %{
        event: "replaced",
        reason: "sprite_gone",
        sandbox_id: new_sandbox_id,
        message: message
      })
    end)
  end

  defp strand_cotenants([], _old_sandbox_id), do: :ok

  defp strand_cotenants(ids, old_sandbox_id) do
    message =
      "The sandbox this conversation was on is gone. It named a different environment " <>
        "or vault from the conversation that replaced the machine, so it did not follow " <>
        "onto that one; its next prompt builds a machine from what it declares. The " <>
        "transcript is kept, and the agent starts a new session."

    MachineEvents.tell_cotenants(ids, old_sandbox_id, "reset", "sprite_gone", message)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # `sandbox_id` is left naming the retired row on purpose: `wake_conversation/2`
    # reads a terminated row as `:create_new` and provisions from this
    # conversation's own environment and vault.
    Repo.update_all(from(c in Conversation, where: c.id in ^ids),
      set: [runtime_session_id: nil, updated_at: now]
    )

    Enum.each(ids, fn id ->
      Conversations.publish_stage(id, "sandbox", "done", %{
        event: "reset",
        reason: "sprite_gone",
        message: message
      })
    end)
  end

  # ownership: sandbox_id below is the waking conversation's own sandbox_id,
  # passed down from wake_conversation_for/3 / create_fresh_sandbox_and_start/4
  # above.
  #
  # Through the machine's owner since ADR 0058 stage 7b, with the provider step
  # skipped. Every caller here has already established that there is no machine
  # to destroy: the replaced row's disk is the one `probe_sandbox/4` was just
  # told is gone, and the two cleanup calls name a row this wake created and
  # never built anything on. `provider: :already_gone` says exactly that, so
  # this costs no provider round trip — and going through the door is what buys
  # the rest of it: the retire is serialized against whatever else holds the
  # machine, and it records the `sandbox.destroyed` every other retirement in
  # this tree has recorded since stage 5.
  #
  # The row ends `terminated` as it always did. The behaviour that is new is
  # that it can be *refused*, which is why `retire_replaced_home/2` answers
  # rather than being discarded — see its one checked caller.
  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    # ownership: `sandbox_id` is the waking conversation's own, passed down from
    # `wake_conversation_for/3` or `create_fresh_sandbox_and_start/4`, which
    # established the conversation's tenant before either reached here.
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        :ok

      sb when sb.status in ["terminated", "failed"] ->
        :ok

      # ownership: as the read above — this is the row it just returned.
      _sb ->
        Termination._unsafe_destroy_machine(sandbox_id,
          actor: "system:wake",
          destroy_reason: :replaced,
          reason: "sandbox_replaced",
          terminating_conversation_id: nil,
          provider: :already_gone
        )
    end
  end

  # Re-read rather than judged from the row `maybe_reuse_sandbox/1` saw: three
  # seconds of `await_registered/2` have passed since, which is long enough for
  # a provision to have finished or for one to have started.
  defp provisioning_owner_live?(sandbox_id) do
    # ownership: `sandbox_id` came from `maybe_reuse_sandbox/1`, which read it
    # off the conversation `wake_conversation_for/3` established the tenant of.
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil -> false
      sandbox -> Machine.busy?(sandbox)
    end
  end

  # The one caller that cannot carry on without it. A persistent home is retired
  # *before* its replacement is created, because the partial unique index allows
  # one live home per identity — so a refused retire is a `create_sandbox/1`
  # that is certain to fail on the index. Answering `:sandbox_unavailable` here
  # gives the caller the 503 and the `Retry-After` that describe what actually
  # happened, rather than a constraint error.
  defp retire_replaced_home(mode, _sandbox_id) when mode != "persistent", do: :ok

  defp retire_replaced_home(_mode, sandbox_id) do
    case mark_old_sandbox_terminated(sandbox_id) do
      {:error, _reason} -> {:error, :sandbox_unavailable}
      _settled -> :ok
    end
  end
end
