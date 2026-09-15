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
  """

  import Ecto.Query

  require Logger

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, Launch, MachineEvents, Sandbox}
  alias Fountain.Repo

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
      when not is_nil(at) and status not in ["terminated", "failed"] ->
        {:error, :sandbox_reset_pending}

      %{status: status, machine_name: name} = sandbox
      when status in ["ready", "suspended"] and is_binary(name) ->
        probe_reusable_sandbox(sandbox, sandbox_id)

      # A provision is in flight — or was, in a BEAM that is gone. The
      # caller waits for the registry before deciding which (#800).
      %{status: status} when status in ["pending", "starting"] ->
        {:provisioning, sandbox_id}

      _ ->
        :create_new
    end
  end

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
  def probe_sandbox(provider, name, status, sandbox_id) do
    case Managoat.Sandbox.get(Managoat.Sandbox.build_handle(provider, name)) do
      {:ok, _info} ->
        {:reuse, sandbox_id}

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

  # Waking a suspended sandbox turns a parked sprite back into compute, so it
  # re-runs the quota gate — under the same advisory lock as creation, with the
  # row re-read inside. Two concurrent wakes both probe `suspended`; the loser
  # re-reads the winner's `ready` flip and must not double-stamp the clock.
  # `exclude: sandbox_id` makes the check identical for both ("does the user
  # have capacity besides this sandbox"), so the loser is never spuriously
  # refused at the cap for a wake that added no concurrency.
  #
  # The second leaf `wake_conversation_for/3` calls, once ownership is
  # established there; `sandbox_id` is the conversation's own row.
  def wake_suspended_sandbox(user_id, sandbox_id) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: "suspended"} ->
        Fountain.Quotas.with_sandbox_reservation(user_id, [exclude: sandbox_id], fn ->
          case Conversations._unsafe_get_sandbox(sandbox_id) do
            %Sandbox{status: "suspended"} = sandbox ->
              resume_and_wake(sandbox)

            sandbox ->
              {:ok, sandbox}
          end
        end)

      sandbox ->
        {:ok, sandbox}
    end
  end

  # Resume BEFORE the row flips: if the provider's wake call fails, the row
  # stays `suspended` and the wake fails retryably — the parked disk is the
  # agent's memory, and a row marked ready over a still-parked backend would
  # strand it. For Sprites resume is a probe (waking is a side effect of the
  # next exec); for pause/stop providers it is the call that restarts the
  # sandbox.
  #
  # Runs under `wake_suspended_sandbox/2`'s reservation lock (see the
  # lock-order note there); a leaf of it, not called directly by the wake
  # door.
  def resume_and_wake(sandbox) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    case Managoat.Sandbox.resume(handle) do
      {:ok, _handle} ->
        Conversations.update_sandbox(sandbox, %{
          status: "ready",
          last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:error, reason} ->
        Logger.warning(
          "resume failed for suspended sandbox #{sandbox.id} (#{inspect(reason)}); " <>
            "leaving it parked"
        )

        {:error, :sandbox_resume_failed}
    end
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
    with {:ok, pid} <-
           Horde.DynamicSupervisor.start_child(
             Fountain.ConversationSupervisor,
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
        {:reuse, sandbox_id} ->
          # Reuse provisions nothing, so the fresh-path gates below never ran
          # here — a canceled or suspended user could restart a server against
          # a live sprite and keep prompting (#313). Same checks. Reusing a
          # `ready` sandbox adds no concurrency, so no quota; waking a
          # `suspended` one re-adds compute, so wake_suspended_sandbox re-runs
          # the quota gate. The per-turn gate in ConversationServer is the
          # backstop; this one makes the refusal synchronous at the API door.
          with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
               :ok <- Fountain.Billing.check_spend(conv.user_id),
               :ok <- Conversations.check_saved_inference(conv, agent),
               {:ok, _} <- wake_suspended_sandbox(conv.user_id, sandbox_id) do
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
              create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt)
          end

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
    if mode == "persistent", do: _ = mark_old_sandbox_terminated(conv.sandbox_id)

    with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
         :ok <- Fountain.Billing.check_spend(conv.user_id),
         :ok <- Conversations.check_saved_inference(conv, agent),
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
  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        :ok

      sb when sb.status in ["terminated", "failed"] ->
        :ok

      sb ->
        Conversations.update_sandbox(sb, %{
          status: "terminated",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end
end
