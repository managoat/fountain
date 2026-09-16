defmodule Fountain.Machines.Destroy do
  @moduledoc """
  One destroy protocol for one machine (ADR 0058, stage 5).

  Every conversation-side destroy used to be the same five steps written out
  again: fence admission, call the provider, write the row terminal, tell the
  co-tenants, and hope nothing else was doing the same thing at the same time.
  `Fountain.Conversations.Lifecycle.do_destroy/4`,
  `ConversationServer.terminate_machine/2` and
  `Termination.retire_terminated_sandbox/2` each had their own version, and
  the third one had no provider call at all — it fenced the row, retired it,
  and left the sprite for the reaper's next pass. This module is those five
  steps once, and the sites now ask for them.

  Stage 5b added the forced-teardown side to the same door:
  `Termination.destroy_home/2` (an agent's homes when the agent is deleted),
  `Accounts.Deletion.destroy_sprites/2`, `SandboxReaper.expire/3` and
  `Termination.reap_sandbox/2`'s dead-server arm. What makes those *forced* is
  one option: they pass `terminating_conversation_id: nil`, so the fence has no
  conversation to keep the machine for and `{:ok, :kept}` is unreachable — a
  home is destroyed because its agent is gone, and an expired machine nobody
  can reach is destroyed even though idle conversations are still bound to it.
  Passing a conversation id on any of those paths would answer `:kept` and
  leave the machine billing forever, which is the 5a lesson stated as a rule.

  ## The steps

  1. Refuse an enclosing transaction. Provider I/O is never inside a lock or a
     transaction (ADR 0058; #2309), and every step below is its own short
     transaction or none.
  2. **Claim a lease** (`Fountain.Machines.Lease.claim/4`) for one operation.
     A lease held by someone else is waited on, briefly, then refused as
     `{:error, :machine_busy}`. The owner process does **not** hold a standing
     lease yet — that arrives with `park` and `ensure_up` in stages 6 and 7 —
     so this lease bounds this destroy and nothing more.
  3. **Fence** with `Lifecycle.fence_sandbox_for_teardown/2`, the fence that
     already exists. This is what makes a mixed-version rollout safe: a
     replica that has not been given this code still honours
     `teardown_requested_at`, so the machine is closed to admission on every
     node whatever the gate says. The gate chooses in-process or inline; it
     does not choose whether the fence is written.
  4. **Stamp the intent**: `transition: "destroying"` by compare-and-set on
     the lease epoch, before any provider I/O. A reader that finds it sees
     what is being done to the machine rather than racing it, and a takeover
     after a crash sees where the previous owner got to.
  5. **Destroy at the provider**, outside every transaction and every lock.
     An already-gone machine (`:not_found`) is success. Any other provider
     error is logged and does **not** stop the finalize: that is what every
     one of the three sites did before this module existed ("a provider error
     still retires the fenced row for reconciliation",
     `termination_actor_fence_test.exs`), and the reaper's untracked-sprite
     report is the backstop for the sprite it leaves behind.
  6. **Finalize**: `status: "terminated"` and the transition cleared, again by
     compare-and-set on the epoch. Zero rows means a newer epoch owns the
     machine, which is `{:error, :superseded}` — this destroy changed nothing
     and the caller must not report that it did.
  7. Release the lease. A lost release is harmless: the epoch is spent either
     way, and the next claimant takes a higher one.
  8. **Audit** `sandbox.destroyed` after the finalize has committed and
     outside every transaction, carrying the actor the caller supplied
     (ADR 0013's vocabulary, unchanged). `sandbox.teardown_requested` from
     step 3 stays where it is, and `audit: false` does not reach it — a caller
     may silence the completion it is about to delete the subject of, never
     the intent the fence recorded.
  9. **Tell the co-tenants**, through `MachineEvents.tell_cotenants/5`, the
     one sender of that cast — when the caller supplies the notice to send.

  ## Takeover

  A claim that finds `transition: "destroying"` on a row that is **not yet
  terminal** is looking at a destroy whose owner died between step 4 and step
  6. It skips the fence (already written) and the stamp (already there) and
  continues from step 5, which is safe because destroying a machine twice is
  destroying it once — the second call answers `:not_found`.

  The status check in front of that is not defensive padding.
  `SandboxReaper.finish_teardown/1` writes an abandoned teardown terminal
  through `Conversations.update_sandbox/2`, which knows nothing about
  `transition` and leaves the stamp on, so a *finished* destroy still wearing
  the stamp is an ordinary state of the fleet. Continuing from it would call
  the provider again and record a second `sandbox.destroyed` for a machine that
  was already gone. Such a row answers `{:ok, :already_terminal}` and has its
  stale stamp cleared.

  That idempotence is the *sequential* argument, and it is the only one stage
  5a makes. Nothing renews the lease across the provider call — the renew timer
  arrives with the standing lease in stages 6 and 7 — so a provider destroy
  slower than `lease_ttl_ms/0` outlives its lease, and a second destroy that
  claims on expiry calls the provider *concurrently* with the first. That is
  therefore a requirement on `Managoat.Sandbox.destroy/1`: two overlapping
  destroys of one machine must be safe, not merely two sequential ones. Every
  adapter satisfies it today (each is a delete by name); an adapter that stops
  satisfying it breaks this module.

  A provider adapter that *raises* rather than answering is caught and treated
  exactly like an error return — logged in full, the finalize still runs. The
  machine was not reached either way, and a fenced row stranded in a live
  status because a provider client blew up is the leak `SandboxReaper`'s
  moduledoc was written about.

  ## Outcomes

  `{:ok, :destroyed}` did the work. `{:ok, :kept}` is the fence's
  `:sandbox_kept`: a persistent home, or a co-tenant still holding the
  machine, so nothing was destroyed and nothing was written.
  `{:ok, :already_terminal}` is a row that had already stopped. Each of the
  three is an outcome a caller can report.

  The `{:error, _}` shapes here are the *protocol's* vocabulary —
  `:machine_busy`, `:superseded`, and whatever the fence or `Lease` hands back,
  including `Lease`'s `{:database, sqlstate}`. They are precise on purpose and
  they are **not** the vocabulary the rest of the system speaks:
  `Fountain.Machines.Machine.destroy/2` is the door, and it translates them
  before anything user-facing sees them.

  Step 1's transaction guard is process-local, which matters once the gate is
  on: the protocol then runs in the owner process, which is never inside the
  caller's transaction, so the guard cannot fire there. `Machine.destroy/2`
  checks before it dispatches for exactly that reason.
  """

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.MachineEvents
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  require Logger

  @typedoc """
  What a destroy did. `:destroyed` ran the protocol through; `:kept` is the
  fence refusing on a home or a co-tenant; `:already_terminal` is a row that
  had already stopped.
  """
  @type outcome :: :destroyed | :kept | :already_terminal

  # How long a holder may hold the machine. One destroy is seconds of provider
  # I/O; a minute is long enough that a slow one keeps its lease to the end,
  # and short enough that a holder killed mid-flight leaves the machine
  # claimable again inside a deploy's window.
  @lease_ttl_ms 60_000

  # How long a *waiter* waits for that holder, which is a different question
  # and was once the same number. The TTL bounds the holder; this bounds the
  # caller, and the caller is usually a person: an HTTP `DELETE` on the
  # dead-server path, or a `ConversationServer` whose own client gives up at
  # `conversation_call_timeout_ms` (30s). A wait that outlives its caller
  # wedges a server for longer than anyone is listening and answers a word —
  # `provisioning` — that means the opposite of what happened. Giving up in
  # five seconds and letting the fence and `SandboxReaper` finish the job is
  # strictly better. `machine_bounds_test.exs` pins this against both ceilings.
  @busy_wait_ms 5_000

  # How often the wait re-asks. The contended case is two destroys of the same
  # machine arriving together, so this is a handful of polls, not hundreds.
  @poll_ms 250

  # Where a machine stops. Same two as `Fountain.Conversations`'
  # `@billable_terminal` and `Lease`'s `@terminal_statuses`.
  @terminal_statuses ~w(terminated failed)

  @doc """
  Destroy the machine behind `sandbox_id`.

  Options:

    * `:actor` (required) — the audit actor for `sandbox.destroyed`, from
      ADR 0013's closed vocabulary (`"self"`, `"api"`, `"ui"`, `"admin"`,
      `"admin:<id>"`, `"system:<worker>"`). Passed to the fence too, which
      folds `admin:<id>` to `admin` for its own event.
    * `:reason` (required, an atom) — `:terminated`, `:idle`, `:max_lifetime`,
      `:reclaimed`. Becomes `transition_reason` on the row and `"reason"` in
      the audit metadata.
    * `:fence_reason` — the string the fence's own
      `sandbox.teardown_requested` event carries, when it differs from
      `reason`. Defaults to `to_string(reason)`. A dead-server terminate wants
      `"conversation_terminated"` here and `:terminated` above, which is the
      case this option exists for.
    * `:terminating_conversation_id` — the conversation being ended, for the
      fence's conversation-then-sandbox lock order and its kept-machine
      decision. **Supplying it is what asks for `{:ok, :kept}`**: without it
      the fence has no conversation to keep the machine *for*, and a home or a
      shared machine is destroyed rather than kept. The reclaim path leaves it
      out for exactly that reason.
    * `:metadata` — extra keys merged into the fence's event, for a caller
      whose own delete is about to nilify `user_id` on the row it names.
    * `:request_ip` — attribution, passed to both events.
    * `:audit` — `false` suppresses the `sandbox.destroyed` event. The fence's
      `sandbox.teardown_requested` is unaffected: that one is
      `Lifecycle.fence_sandbox_for_teardown/2`'s and is written whatever this
      says. Defaults to `true`, and exactly one caller passes `false` —
      `Fountain.Accounts.Deletion`, whose own `terminate_conversation(audit:
      false)` has always suppressed the per-conversation events for the same
      reason: `audit_events.user_id` is nilified by the delete seconds later,
      so a per-machine row would survive as an orphan describing a cascade,
      and `account.deleted` already carries the identity (#2344, stage 5b).
      Note this is *not* the `user_id: nil` skip below — at destroy time the
      row still names its tenant, so that clause does not fire.
    * `:notify` — `{conversation_id, event, reason, message}`, the notice to
      cast to the machine's other conversations once it is gone. Omitted by
      every caller that has nothing to say, and there are two kinds. A caller
      whose fence ran with a `terminating_conversation_id` has already
      established there is nobody else on the machine. A **forced** caller has
      established the opposite — its fence is unconditional precisely because
      co-tenants may be bound — and still omits it: an agent deletion, an
      account deletion, an expiry and an admin reap are not reclamations a
      conversation can be told to expect a new machine after, and none of the
      four notified before ADR 0058 either. Giving them wording is a decision
      for whoever needs one, not a default.
    * `:lease_ttl_ms` — how long this operation's lease lives. Defaults to
      #{@lease_ttl_ms}.
    * `:busy_wait_ms` — how long to wait for a lease somebody else holds.
      Defaults to #{@busy_wait_ms}. Tests shorten it; no call site does.
  """
  @spec run(Ecto.UUID.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    opts = validated(opts)

    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      claim_and_destroy(sandbox_id, opts)
    end
  end

  @doc """
  How long `run/2` waits for a lease somebody else holds before refusing.

  Public so `machine_bounds_test.exs` can pin it against the two ceilings it
  has to sit under — `Machine`'s call timeout and `conversation_call_timeout_ms`
  — rather than against a number a test passed in itself.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  @doc "How long one operation's lease lives. See `busy_wait_ms/0`."
  @spec lease_ttl_ms() :: pos_integer()
  def lease_ttl_ms, do: @lease_ttl_ms

  # The two required options, checked before anything is claimed or written.
  # Both are caller bugs rather than runtime conditions — a destroy with no
  # actor records an event ADR 0013 has no word for, and a reason that is not
  # an atom reaches the row as `transition_reason` and the trail as `"reason"`
  # in whatever shape it arrived in — so they raise rather than answer.
  defp validated(opts) do
    _actor = Keyword.fetch!(opts, :actor)

    case Keyword.fetch!(opts, :reason) do
      reason when is_atom(reason) and not is_nil(reason) ->
        opts

      other ->
        raise ArgumentError, "Machines.Destroy: :reason must be an atom, got #{inspect(other)}"
    end
  end

  # ── the lease around one operation ────────────────────────────────────────

  defp claim_and_destroy(sandbox_id, opts) do
    ttl_ms = Keyword.get(opts, :lease_ttl_ms, @lease_ttl_ms)

    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

    case claim(sandbox_id, ttl_ms, deadline) do
      {:ok, epoch} ->
        try do
          under_lease(sandbox_id, epoch, opts)
        after
          # `after`, not a plain next statement: an adapter that *raises*
          # unwinds through here, and a lease left held would otherwise keep
          # this machine unclaimable for a whole TTL — long enough that the
          # next terminate of it waits out `@busy_wait_ms` and refuses, for a
          # failure that already happened. Releasing keeps the epoch, so it is
          # safe on every path, including one that has already been superseded.
          # Best effort and deliberately not matched on: a destroy that
          # finished is finished whether or not its lease came back.
          _ = Lease.release(sandbox_id, epoch)
        end

      {:error, _} = error ->
        error
    end
  end

  # A lease someone else holds is waited out rather than refused outright: two
  # destroys of one machine arriving together is the ordinary case (a reaper
  # pass and a user's terminate), and the second one wants the first one's
  # answer, not an error. The wait is bounded by `@busy_wait_ms` and not by the
  # TTL: how long a holder may hold is not how long a caller should wait.
  defp claim(sandbox_id, ttl_ms, deadline) do
    case Lease.claim(sandbox_id, node_name(), ttl_ms) do
      {:ok, epoch} ->
        {:ok, epoch}

      {:error, {:held, holder, until}} ->
        if System.monotonic_time(:millisecond) + @poll_ms < deadline do
          Process.sleep(@poll_ms)
          claim(sandbox_id, ttl_ms, deadline)
        else
          Logger.warning(
            "machine #{sandbox_id}: destroy refused, lease held by #{holder} until #{inspect(until)}"
          )

          {:error, :machine_busy}
        end

      {:error, _} = error ->
        error
    end
  end

  defp node_name, do: to_string(node())

  # ── the protocol ──────────────────────────────────────────────────────────

  defp under_lease(sandbox_id, epoch, opts) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :not_found}

      # A machine that has already stopped, still carrying the intent of the
      # destroy that stopped it. **Checked before the continuation below**, and
      # that order is the whole point: matching on `transition` alone would
      # send a finished destroy back through the provider and record a second
      # `sandbox.destroyed` for a machine that was gone. Not a forged state —
      # `SandboxReaper.finish_teardown/1` writes `terminated` through
      # `Conversations.update_sandbox/2`, which knows nothing about
      # `transition` and leaves the stamp exactly here.
      %Sandbox{transition: "destroying", status: status} = done
      when status in @terminal_statuses ->
        clear_stale_transition(done, epoch)
        already_terminal(done, opts)

      # Step 4 landed and step 6 did not: the previous holder died in the
      # middle of its provider call, or was superseded before it could
      # finalize. The fence is already written and the intent is already on the
      # row, so this owner picks the work up at step 5.
      %Sandbox{transition: "destroying"} = interrupted ->
        Logger.info(
          "machine #{sandbox_id}: continuing an interrupted destroy " <>
            "(#{interrupted.transition_reason || "no reason"}) at epoch #{epoch}"
        )

        destroy_and_finalize(interrupted, epoch, opts)

      %Sandbox{} = sandbox ->
        fence_then_destroy(sandbox, epoch, opts)
    end
  end

  # Answering `:already_terminal` is the outcome; clearing the stamp is the
  # tidying that makes the column mean something again — while it is set on a
  # terminal row, "is this machine mid-destroy?" cannot be answered from the
  # row, which is the column's only job. A status-free write is not a revival,
  # so `Lease.refuse_revival/2` lets it through on a terminal row; a refusal
  # here is somebody else's business and is logged rather than returned,
  # because the caller's answer does not depend on it.
  defp clear_stale_transition(%Sandbox{} = sandbox, epoch) do
    case Lease.cas_update(sandbox.id, epoch, transition: nil, transition_reason: nil) do
      {:ok, _cleared} ->
        Logger.info(
          "machine #{sandbox.id}: cleared a stale destroying stamp on a #{sandbox.status} row"
        )

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: could not clear a stale destroying stamp (#{inspect(reason)})"
        )
    end

    :ok
  end

  defp fence_then_destroy(sandbox, epoch, opts) do
    # A remote call, so `lifecycle_fence_test.exs` can drive a race on it with
    # Mimic the way `Lifecycle.prepare_destroy/2` already does.
    case Lifecycle.fence_sandbox_for_teardown(sandbox, fence_opts(opts)) do
      {:ok, %Sandbox{status: status} = done} when status in @terminal_statuses ->
        already_terminal(done, opts)

      {:ok, %Sandbox{} = fenced} ->
        stamp_then_destroy(fenced, epoch, opts)

      {:error, :sandbox_kept} ->
        {:ok, :kept}

      {:error, _} = error ->
        error
    end
  end

  defp fence_opts(opts) do
    reason = Keyword.fetch!(opts, :reason)

    [
      actor: Keyword.fetch!(opts, :actor),
      reason: Keyword.get(opts, :fence_reason) || to_string(reason)
    ]
    |> put_unless_nil(:request_ip, Keyword.get(opts, :request_ip))
    # Merged into `sandbox.teardown_requested` by the fence, for a caller whose
    # own delete is about to nilify the `user_id` on the event and the row it
    # names. `main`'s `retire_terminated_sandbox/2` forwarded the caller's whole
    # opts list, so dropping it here would have been a silent narrowing.
    |> put_unless_nil(:metadata, Keyword.get(opts, :metadata))
    |> put_unless_nil(
      :terminating_conversation_id,
      Keyword.get(opts, :terminating_conversation_id)
    )
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp stamp_then_destroy(sandbox, epoch, opts) do
    case Lease.cas_update(sandbox.id, epoch,
           transition: "destroying",
           transition_reason: to_string(Keyword.fetch!(opts, :reason))
         ) do
      {:ok, %Sandbox{} = marked} -> destroy_and_finalize(marked, epoch, opts)
      {:error, :stale} -> {:error, :superseded}
      {:error, :retired} -> already_terminal(sandbox, opts)
      {:error, _} = error -> error
    end
  end

  defp destroy_and_finalize(sandbox, epoch, opts) do
    destroy_at_provider(sandbox)

    case Lease.cas_update(sandbox.id, epoch,
           status: "terminated",
           transition: nil,
           transition_reason: nil
         ) do
      {:ok, %Sandbox{} = terminated} ->
        # The two effects `update_sandbox/2` would have run — the
        # `sandbox_terminated` usage row and the sandbox-queue poke that turns
        # this tenant's freed slot into a drain. After the write commits and
        # outside every transaction, with the status the row carried *going
        # into* the finalize rather than a fresh reload, which is the same rule
        # `update_sandbox_if/3` follows with its `FOR UPDATE` read (#2309).
        Conversations.sandbox_status_effects(terminated, sandbox.status)

        # Both after the finalize commits, in this order: the trail is the
        # durable record and must not depend on a cast reaching anybody.
        audit(terminated, opts)
        notify_cotenants(terminated, opts)
        {:ok, :destroyed}

      {:error, :stale} ->
        # A newer epoch owns this machine. The provider call above may well
        # have succeeded; the takeover reads the row's true state and is the
        # one allowed to say what happened to it.
        Logger.warning("machine #{sandbox.id}: destroy superseded before its finalize")
        {:error, :superseded}

      {:error, :retired} ->
        already_terminal(sandbox, opts)

      {:error, _} = error ->
        error
    end
  end

  # Somebody else stopped this machine. The caller's own bookkeeping still has
  # to run, and so does the co-tenant notice: `main`'s `do_destroy/4` called
  # `stop_cotenants/5` unconditionally, and a co-tenant server still holding a
  # handle to a machine that is already gone is exactly what it exists to stop.
  defp already_terminal(%Sandbox{} = sandbox, opts) do
    notify_cotenants(sandbox, opts)
    {:ok, :already_terminal}
  end

  # ── the provider ──────────────────────────────────────────────────────────

  # There is no "no machine to call" case to handle: `sprite_name` is `NOT
  # NULL` in the database and required by `Sandbox.changeset/2`, so a row that
  # exists names a machine.
  defp destroy_at_provider(%Sandbox{} = sandbox) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        :ok

      # Already gone is the outcome asked for.
      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        provider_gave_up(sandbox, reason)
    end
  rescue
    # An adapter that raises rather than answering is the same *outcome* as one
    # that returns an error — this machine was not reached — so it gets the same
    # treatment, and for the same reason: a fenced row must not be stranded in a
    # live status because a provider client blew up. `main` let the raise
    # through and paid for it with a row nobody could find (`SandboxReaper`'s
    # moduledoc lists that leak); catching it here means the row retires, the
    # trail records the destroy, and the reaper's untracked-sprite pass reports
    # the machine. The exception is logged in full so the adapter bug is still
    # visible.
    error ->
      provider_gave_up(sandbox, Exception.format(:error, error, __STACKTRACE__))
  end

  # Logged, not returned: the fenced row is retired either way, so the fleet
  # sees a terminal row rather than a live one nobody can find, and
  # `Workers.SandboxReaper`'s pass over terminal rows whose sprite is still
  # there is what eventually collects the machine.
  defp provider_gave_up(%Sandbox{} = sandbox, reason) do
    Logger.warning(
      "machine #{sandbox.id}: provider destroy failed for #{sandbox.machine_name} " <>
        "on #{sandbox.provider}: #{inspect(reason)}"
    )

    :ok
  end

  # ── after the finalize ────────────────────────────────────────────────────

  # Two ways a completed destroy records nothing, from opposite ends of the
  # same delete.
  #
  # `audit: false` is a caller that has asked for silence, and one does:
  # `Accounts.Deletion` is about to delete the tenant, which nilifies
  # `audit_events.user_id`, so a per-machine row would outlive its subject as
  # an orphan describing a cascade. That is the same judgement its own
  # `terminate_conversation(audit: false)` already makes about the
  # per-conversation events, and the reason `account.deleted` denormalises the
  # identity into its own metadata (#2344, stage 5b decision).
  #
  # A nil `user_id` is a row that has *already* lost its tenant — the #2329
  # trap, an account deletion that nilified before its machines were torn down.
  # An audit row with no `user_id` is a system event surfaced only in admin
  # views and would say nothing the deletion's own trail does not, so it is
  # skipped rather than recorded unattributed. Stage 5b's deletion caller does
  # not reach this clause (it suppresses through `:audit`, while `user_id` is
  # still set); `Principals` release and a partly-completed delete can.
  #
  # The fence's `sandbox.teardown_requested` is not suppressed by either: it is
  # `Lifecycle.fence_sandbox_for_teardown/2`'s event, written before this is
  # ever consulted, and a teardown that was requested still happened.
  defp audit(%Sandbox{} = sandbox, opts) do
    cond do
      not Keyword.get(opts, :audit, true) -> :ok
      is_nil(sandbox.user_id) -> :ok
      true -> record_destroyed(sandbox, opts)
    end
  end

  defp record_destroyed(%Sandbox{} = sandbox, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: "sandbox.destroyed",
      resource_type: "sandbox",
      resource_id: sandbox.id,
      # Folded the same way the fence folds it (`Lifecycle.teardown_actor/1`):
      # ADR 0013 reserves `admin:<operator_id>` for account deletion alone, so
      # an operator reaping a machine records the plain `admin` the vocabulary
      # allows. Stage 5b's admin reap is the first caller that supplies the id
      # form, and the two events a destroy leaves have to agree on the actor
      # whichever stage wrote the caller.
      actor: Lifecycle.teardown_actor(Keyword.fetch!(opts, :actor)),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "reason" => to_string(Keyword.fetch!(opts, :reason)),
        "provider" => sandbox.provider,
        "sprite_name" => sandbox.machine_name
      }
    })

    :ok
  end

  # The machine is gone, so every other conversation bound to it has lost its
  # handle. Only a caller that knows what to say says it: the wording is the
  # caller's ("reclaimed" and the bound that reclaimed it, today), and the two
  # paths that fence with a terminating conversation have already established
  # there is nobody else here.
  defp notify_cotenants(%Sandbox{} = sandbox, opts) do
    case Keyword.get(opts, :notify) do
      nil ->
        :ok

      {conversation_id, event, reason, message} ->
        sandbox.id
        |> Conversations._unsafe_list_cotenant_ids(conversation_id)
        |> MachineEvents.tell_cotenants(sandbox.id, event, reason, message)
    end
  end
end
