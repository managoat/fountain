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
  steps once, and the three sites now ask for them.

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
     step 3 stays where it is.
  9. **Tell the co-tenants**, through `MachineEvents.tell_cotenants/5`, the
     one sender of that cast — when the caller supplies the notice to send.

  ## Takeover

  A claim that finds `transition: "destroying"` already stamped on the row is
  looking at a destroy whose owner died between step 4 and step 6. It skips
  the fence (already written) and the stamp (already there) and continues from
  step 5, which is safe because destroying a machine twice is destroying it
  once — the second call answers `:not_found`.

  A provider adapter that *raises* rather than answering is not caught here,
  the same as at every call site this replaced — it is a bug in the adapter,
  not a state of the machine, and swallowing it would hide it. What is new is
  that it is now recoverable: the raise leaves `transition: "destroying"` on
  the row and a lease that expires, which is exactly the state the paragraph
  above describes, so the next destroy of that machine finishes the job
  instead of finding a live row nobody can explain (`SandboxReaper`'s
  moduledoc lists this leak among the ones it was written to sweep up).

  ## Outcomes

  `{:ok, :destroyed}` did the work. `{:ok, :kept}` is the fence's
  `:sandbox_kept`: a persistent home, or a co-tenant still holding the
  machine, so nothing was destroyed and nothing was written.
  `{:ok, :already_terminal}` is a row that had already stopped. Each of the
  three is an outcome a caller can report; every `{:error, _}` is a refusal
  the caller must not paper over.
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

  # One destroy is seconds of provider I/O. A minute is long enough that a slow
  # one keeps its lease to the end, and short enough that a holder killed
  # mid-flight leaves the machine claimable again inside a deploy's window.
  # It is also the bound on the wait below: an operation cannot be busy for
  # longer than the lease that makes it busy can live.
  @lease_ttl_ms 60_000

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
    * `:request_ip` — attribution, passed to both events.
    * `:notify` — `{conversation_id, event, reason, message}`, the notice to
      cast to the machine's other conversations once it is gone. Omitted by a
      caller whose fence already established there are none.
    * `:lease_ttl_ms` — the lease's TTL and the bound on the busy wait.
      Defaults to #{@lease_ttl_ms}.
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
    deadline = System.monotonic_time(:millisecond) + ttl_ms

    case claim(sandbox_id, ttl_ms, deadline) do
      {:ok, epoch} ->
        result = under_lease(sandbox_id, epoch, opts)
        # Best effort, and deliberately not matched on: a destroy that
        # finished is finished whether or not its lease came back, and a
        # superseded owner has nothing left to release.
        _ = Lease.release(sandbox_id, epoch)
        result

      {:error, _} = error ->
        error
    end
  end

  # A lease someone else holds is waited out rather than refused outright: two
  # destroys of one machine arriving together is the ordinary case (a reaper
  # pass and a user's terminate), and the second one wants the first one's
  # answer, not an error. The wait is bounded by the TTL because nothing can
  # legitimately hold the machine for longer than the lease it holds it with.
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

  defp fence_then_destroy(sandbox, epoch, opts) do
    # A remote call, so `lifecycle_fence_test.exs` can drive a race on it with
    # Mimic the way `Lifecycle.prepare_destroy/2` already does.
    case Lifecycle.fence_sandbox_for_teardown(sandbox, fence_opts(opts)) do
      {:ok, %Sandbox{status: status}} when status in @terminal_statuses ->
        {:ok, :already_terminal}

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
      {:error, :retired} -> {:ok, :already_terminal}
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
        {:ok, :already_terminal}

      {:error, _} = error ->
        error
    end
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
        # Logged, not returned: the fenced row is retired either way, so the
        # fleet sees a terminal row rather than a live one nobody can find,
        # and `Workers.SandboxReaper`'s pass over terminal rows whose sprite is
        # still there is what eventually collects the machine.
        Logger.warning(
          "machine #{sandbox.id}: provider destroy failed for #{sandbox.machine_name} " <>
            "on #{sandbox.provider}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ── after the finalize ────────────────────────────────────────────────────

  # Account deletion nilifies `user_id` before its machines are torn down (the
  # #2329 trap), which leaves a destroy with no tenant to attribute. An audit
  # row with a nil `user_id` is a system event surfaced only in admin views and
  # would say nothing here that the deletion's own trail does not, so this one
  # is skipped rather than recorded unattributed. The forced-teardown side is
  # stage 5b and decides that case for itself; no caller in stage 5a reaches
  # this clause.
  defp audit(%Sandbox{user_id: nil}, _opts), do: :ok

  defp audit(%Sandbox{} = sandbox, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: "sandbox.destroyed",
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: Keyword.fetch!(opts, :actor),
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
