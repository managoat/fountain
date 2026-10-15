defmodule Fountain.Conversations.Termination do
  @moduledoc """
  The client half of terminate: what a caller does to end a conversation,
  whether or not its `ConversationServer` is alive.

  Moved out of `Fountain.Conversations.ConversationServer` and
  `Fountain.Conversations.Lifecycle` in #2209 (one owner per lifecycle verb,
  #2175). The server keeps the actor halves — `handle_call({:terminate_conv, ..})`,
  `terminate_machine`, `finish_termination` and OTP `terminate/2` — because
  each needs `state.handle` or orders a row write against the reply.
  Everything here is a function over a conversation id, the registry and rows.

  This module also owns the terminated row itself
  (`_unsafe_finish_conversation_termination/2`, moved from
  `Fountain.Conversations` in #2268), the same way
  `Fountain.Conversations.Interruption` owns the interrupted turn row
  (#2244). The machine fence a forced teardown refuses or commits against is
  `Fountain.Conversations.Lifecycle`'s (#2258) — a rule about the sandbox,
  not a conversation verb; this module calls it, it does not own it.

  Tenant scoping is the caller's job: every public function here is reached
  after a tenant-scoped fetch established ownership at the controller,
  `Fountain.Accounts.Deletion` or a system sweep, exactly as
  when these lived on the server.
  """

  import Ecto.Query
  import Fountain.Conversations.ConversationServer, only: [whereis: 1, call_server: 2]

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Lifecycle, Sandbox}
  alias Fountain.Machines.Machine
  alias Fountain.Repo

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.

  An enclosing database transaction is refused before contacting the actor or
  updating rows, so teardown cannot escape a caller's rollback.

  Named `terminate_conversation` rather than `terminate`: taking `opts` for
  audit attribution (#545) would have made this `terminate/2`, which is the
  OTP callback on `ConversationServer`. Two different meanings under one name in one module was
  already a readability trap — `ConversationServer.terminate/1` (stop this
  tenant's conversation) and `terminate/2` (OTP teardown) are unrelated — so
  the client half gets the unambiguous name.
  """
  def terminate_conversation(conv_id, opts \\ []) do
    if Fountain.Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      # ownership: callers established this conversation's tenant.
      do_terminate_conversation(conv_id, opts)
    end
  end

  defp do_terminate_conversation(conv_id, opts) do
    result =
      case whereis(conv_id) do
        nil ->
          # ownership: established by the caller before terminate_conversation/2.
          case Conversations._unsafe_get_conversation(conv_id) do
            nil ->
              {:error, :not_running}

            conv ->
              with {:ok, terminated} <-
                     Conversations.update_conversation(conv, %{status: "terminated"}) do
                retire_terminated_sandbox(terminated, opts)
              end
          end

        pid ->
          # `:audit_destroy` travels with the attribution (ADR 0058 stage 5b
          # review): the server forwards its whole opts list to
          # `_unsafe_destroy_machine/2`, so this narrowing was the only thing
          # keeping account deletion's suppression off the live-server path —
          # a machine whose conversation still had a server left one
          # `sandbox.destroyed` behind, and the delete then nilified its
          # `user_id`, which is the orphaned row this module refuses to write.
          call_server(
            pid,
            {:terminate_conv, Keyword.take(opts, [:actor, :request_ip, :audit_destroy, :destroy])}
          )
      end

    audit_lifecycle(conv_id, "conversation.terminated", result, opts)
    result
  end

  @doc """
  Destroy the machine of a conversation that is ending, through its owner
  (ADR 0058 stage 5).

  `_unsafe_`: a bare `sandbox_id` and no tenant scoping here. Every caller
  established the conversation this machine belongs to first.

  One door for every destroy this tree asks for — both halves of terminate,
  and since stage 5b the forced teardowns (`reap_sandbox/2`,
  `Accounts.Deletion` and `Workers.SandboxReaper`'s expiry) — so the fence, the
  provider destroy, the terminal write and the `sandbox.destroyed` event are
  the same five steps whichever caller ran.

  **`:terminating_conversation_id` says which call's fence decides**, and it is
  required rather than defaulted: a caller that does not state it has not
  thought about the one option that decides whether the machine survives. The
  halves answer it differently:

    * **the conversation's id**, from the dead-server path, where this fence is
      the first and only look at the machine. A persistent home or a live
      co-tenant then answers `{:ok, :kept}` and nothing is touched — the
      kept-machine semantics this path has always had.
    * **`nil`**, from a live server that already ran `Machine.detach/2` and
      acted on its verdict. The protocol still fences — a repeat, which writes
      no second intent and is what keeps a mixed-version fleet safe — but it
      must not decide the binding a second time. By then the turn has been
      interrupted and the adapter closed, and a conversation rebound to another
      machine in between would make the second decision `:sandbox_kept`,
      leaving this machine fenced, live and billing with no server left to
      finish it.
    * **`nil` again**, from every forced teardown. A home whose agent is gone,
      a tenant's machines during account deletion, an abandoned machine past
      its ceiling and an admin reap are all operations *on the machine*, not
      on one conversation, and none of them has a conversation to keep it for.
      There the fence is the first look at the machine and `nil` is what keeps
      it forced: an idle conversation still bound to the row must not turn the
      destroy into `{:ok, :kept}`, because an unexpirable machine bills
      forever.

  The two reasons are deliberately different words, and different options.
  `:destroy_reason` is the machine's transition and what the
  `sandbox.destroyed` event says happened (`:terminated` unless the caller
  names another); `:reason` is what the fence's `sandbox.teardown_requested`
  event has always said, and changing that would rewrite a trail operators
  already read.

  Three options steer the protocol rather than describing the operation, and
  all three are forwarded untouched because the reset family is a caller of
  this door too (ADR 0058 stage 5c). `:fence` is `:held_by_caller` for a
  caller that already holds a durable fence — the reset's `destroying` stamp,
  reason `"reset"` — so the teardown fence is not written on top of it; `:provider` is
  `:already_gone` when the caller has already probed and been told the machine
  does not exist; `:on_provider_error` is `:refuse` for a caller whose fence
  must survive an unconfirmed delete. `Fountain.Machines.Destroy` documents
  what each one costs. Every other caller takes the defaults and behaves
  exactly as it did in 5a and 5b.

  `:notify` is forwarded as the protocol takes it (ADR 0058 stage 8b): `Wake`
  hands the co-tenants of a replaced machine here in two groups, and the
  destroy is what tells them.

  `:audit_destroy` is the machine event's own switch and is spelled apart from
  `:audit` on purpose. `terminate_conversation/2`'s `:audit` means the
  *conversation* event, and it arrives here in the same opts list on the
  dead-server path (`retire_terminated_sandbox/2` forwards its caller's opts
  whole); letting it silence the machine event too would mean every
  `delete_conversation/2` quietly stopped recording `sandbox.destroyed`.
  """
  @spec _unsafe_destroy_machine(String.t(), keyword()) ::
          {:ok, Fountain.Machines.Destroy.outcome()} | {:error, term()}
  def _unsafe_destroy_machine(sandbox_id, opts) do
    Machine.destroy(sandbox_id,
      actor: Keyword.get(opts, :actor, "self"),
      reason: Keyword.get(opts, :destroy_reason, :terminated),
      fence_reason: Keyword.get(opts, :reason, "conversation_terminated"),
      terminating_conversation_id: Keyword.fetch!(opts, :terminating_conversation_id),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Keyword.get(opts, :metadata),
      audit: Keyword.get(opts, :audit_destroy, true),
      fence: Keyword.get(opts, :fence, :teardown),
      provider: Keyword.get(opts, :provider, :destroy),
      on_provider_error: Keyword.get(opts, :on_provider_error, :finalize),
      notify: Keyword.get(opts, :notify)
    )
  end

  @doc """
  Retire the machine of an authorized, terminated conversation with no actor.

  The conditional fence preserves homes and other live co-tenants and blocks
  new attachments; past it, the machine is destroyed at the provider and the
  row retired, through `_unsafe_destroy_machine/2`. **This is where it used to stop.**
  Before ADR 0058 stage 5 this path fenced the row, wrote it terminal and left
  the sprite standing for `Workers.SandboxReaper`'s next pass to notice and
  collect — up to an hour of a machine nobody could reach still billing. The
  reaper's terminal-row pass is still the safety net; it is no longer the
  mechanism.

  The caller owns the conversation lifecycle audit; the two machine events —
  the fence's intent and the destroy — carry the supplied attribution.
  """
  def retire_terminated_sandbox(%{sandbox_id: nil}, _opts), do: :ok

  def retire_terminated_sandbox(conv, opts) do
    # ownership: this sandbox belongs to the conversation authorized by the
    # caller; the detach rechecks the binding under its lock.
    #
    # The last-detach decision and, when the machine goes, its destroy, in one
    # call to the owner (ADR 0058 stage 8b): nothing has fenced this machine
    # yet, so the detach's fence is the decision — it keeps a home or a machine
    # a co-tenant still holds — and with no adapter to close in between,
    # `destroy: true` lets the protocol finish it.
    #
    # `destroy: :background` (#2561) splits that call at the fence: the
    # decision commits here, and a machine that is going is destroyed in a task
    # after the caller has its answer. `destroy_after_terminate/2` says why
    # that is safe.
    background? = Keyword.get(opts, :destroy) == :background

    case Machine.detach(conv.sandbox_id,
           conversation_id: conv.id,
           destroy: not background?,
           actor: Keyword.get(opts, :actor, "self"),
           reason: Keyword.get(opts, :reason, "conversation_terminated"),
           destroy_reason: Keyword.get(opts, :destroy_reason, :terminated),
           request_ip: Keyword.get(opts, :request_ip),
           metadata: Keyword.get(opts, :metadata),
           audit: Keyword.get(opts, :audit_destroy, true)
         ) do
      {:ok, :detached} when background? ->
        destroy_after_terminate(
          conv.sandbox_id,
          Keyword.put(opts, :terminating_conversation_id, nil)
        )

      {:ok, _outcome} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Destroy a fenced machine at the end of a conversation's termination: in the
  caller, or with `destroy: :background` in `opts` (#2561), in a task under
  `Fountain.TaskSupervisor`, so the request that ended the conversation does
  not wait on the provider (up to 16 s in prod).

  Safe to leave behind because the decision is already durable. The fence has
  stamped the row `destroying` before this runs, so no wake, attach or read
  reaches the machine (`Wake.maybe_reuse_sandbox/1` refuses it), the destroy
  continues from that stamp, and a destroy that fails or never runs, because
  its node went down, is finished by the reaper's sweep of fenced rows as any
  interrupted destroy is. A provider error is logged either way, as the server
  has always done; the conversation is terminated regardless.

  Account deletion and the other internal callers keep the default: they act
  on the machine being gone.
  """
  @spec destroy_after_terminate(String.t(), keyword()) :: :ok
  def destroy_after_terminate(sandbox_id, opts) do
    destroy = fn ->
      case _unsafe_destroy_machine(sandbox_id, opts) do
        {:ok, _outcome} -> :ok
        {:error, reason} -> Logger.warning("sandbox #{sandbox_id}: destroy: #{inspect(reason)}")
      end
    end

    if Keyword.get(opts, :destroy) == :background do
      {:ok, _pid} = Task.Supervisor.start_child(Fountain.TaskSupervisor, destroy)
    else
      destroy.()
    end

    :ok
  end

  @doc """
  Support teardown of any tenant's sandbox, from the admin panel. Moved from
  `Fountain.Conversations._unsafe_reap_sandbox/1` in #2257 (#2255, tranche 2).

  A conversation with a live `ConversationServer` is terminated through the
  server, which destroys the sprite and ends the conversation — that is what
  stopping a runaway agent means. A sandbox with no live server (including a
  `suspended` one) is destroyed through the machine's owner
  (`_unsafe_destroy_machine/2`): the conversation stays resumable (next prompt
  gets a fresh sandbox, with the agent's memory lost — decisions/0017), and
  since ADR 0058 stage 5b the sprite goes in this call rather than on the
  reaper's next pass. The reaper's terminal-row pass is still the safety net
  for a destroy that could not finish.

  With `admin_user_id:` in `opts`, a successful reap records
  `admin.sandbox.reaped` here, outside any transaction (this function opens
  none) — folded in from the admin controller and `AdminLive.Sandboxes`,
  which used to record the identical event themselves (#2255 decision 4).
  `reap_all_for_user/1` below passes no admin id, so a suspension's reaps
  stay silent, exactly as before.
  """
  def reap_sandbox(sandbox_id, opts \\ []) do
    # ownership: sandbox_id is given by an admin surface behind require_admin
    # (AdminController.reap_sandbox/2, AdminLive.Sandboxes), or by
    # reap_all_for_user/1 below whose own caller (Accounts.suspend_user/1) is
    # admin-driven.
    result =
      case Conversations._unsafe_get_sandbox(sandbox_id) do
        nil ->
          {:error, :not_found}

        %Sandbox{status: s} when s in ["terminated", "failed"] ->
          {:ok, :already_terminal}

        sandbox ->
          sandbox = Fountain.Repo.preload(sandbox, :conversations)
          live_ids = Lifecycle.live_conversation_ids(sandbox)

          if live_ids == [] do
            release_machine(sandbox, opts)
          else
            # A reclaimed sandbox took the tenant's conversations down with it,
            # which is worth a row each — this is the one termination they did
            # not ask for. #551 covers the reaper that calls this.
            Enum.each(
              live_ids,
              &terminate_conversation(&1, actor: "system:sandbox_reaper")
            )

            {:ok, :terminated}
          end
      end

    audit_reap(sandbox_id, result, opts)
    result
  end

  # The arm with nobody home: no live `ConversationServer` anywhere in the
  # cluster, so there is no actor to ask and this is a machine operation with
  # no conversation behind it.
  #
  # It used to write the row `terminated` and stop, leaving the sprite for
  # `Workers.SandboxReaper`'s pass over terminal rows — the same up-to-an-hour
  # gap stage 5a closed on the dead-server terminate. Now it goes through the
  # machine's owner, so the provider machine dies in this call and
  # `sandbox.destroyed` records it (ADR 0058 stage 5b).
  #
  # `terminating_conversation_id: nil`, and that is the point of the reap: an
  # admin stopping a runaway machine, or a suspension taking a tenant's compute
  # away, must not be turned into `{:ok, :kept}` by an idle conversation still
  # bound to the row, or by the row being a persistent home. Reaping a home is
  # exactly what /admin/sandboxes is for.
  #
  # The outcome word stays `:released` whatever the protocol answers. It is the
  # admin surfaces' and `reap_all_for_user/1`'s vocabulary and it lands in
  # `admin.sandbox.reaped`'s metadata; a machine somebody else had already
  # stopped was reported as released before this stage too, because the old
  # write was an unconditional `update_sandbox/2`.
  #
  # ownership: `sandbox` came from the scoped read in `reap_sandbox/2` above,
  # whose own caller is an admin surface or a suspension.
  defp release_machine(%Sandbox{} = sandbox, opts) do
    case _unsafe_destroy_machine(sandbox.id,
           actor: reap_actor(opts),
           destroy_reason: :admin_reap,
           reason: "reaped",
           request_ip: Keyword.get(opts, :request_ip),
           terminating_conversation_id: nil
         ) do
      {:ok, _outcome} -> {:ok, :released}
      {:error, _} = error -> error
    end
  end

  # `admin:<id>` so both machine events fold it to the plain `admin` ADR 0013
  # allows (`Lifecycle.teardown_actor/1`); the id itself is reserved for
  # `account.deleted`, and `admin.sandbox.reaped` already carries it.
  # `reap_all_for_user/1` identifies no admin, and its sweep is the reaper's
  # own work on a suspended tenant.
  defp reap_actor(opts) do
    case Keyword.get(opts, :admin_user_id) do
      nil -> "system:sandbox_reaper"
      admin_user_id -> "admin:#{admin_user_id}"
    end
  end

  # Only on success, and only when the caller identified an admin. A failed
  # reap changed nothing, and reap_all_for_user/1's suspension sweep records
  # nothing per sandbox, per #2255 decision 4.
  defp audit_reap(sandbox_id, {:ok, outcome}, opts) do
    case Keyword.get(opts, :admin_user_id) do
      nil ->
        :ok

      admin_user_id ->
        Fountain.Audit.record_admin(%{
          actor_user_id: admin_user_id,
          target_user_id: nil,
          event_type: "admin.sandbox.reaped",
          metadata: %{"sandbox_id" => sandbox_id, "outcome" => to_string(outcome)}
        })

        :ok
    end
  end

  defp audit_reap(_sandbox_id, _result, _opts), do: :ok

  @doc """
  Reap every active sandbox belonging to `user_id` — the suspension path
  (#287). Moved from `Fountain.Conversations._unsafe_reap_all_for_user/1` in
  #2257 (#2255, tranche 2). Unscoped by the same contract as the `_unsafe_`
  prefix it left behind: legitimate callers are admin-driven
  (`Accounts.suspend_user/1` behind `require_admin`).

  Best-effort by design: each sandbox reaps independently and a failure moves
  on — suspension must not be blocked by one wedged sprite; `SandboxReaper`
  sweeps stragglers. Returns the number of sandboxes reaped.
  """
  def reap_all_for_user(user_id) when is_binary(user_id) do
    # Deliberately wider than the fleet ceiling's statuses: `suspended` is
    # excluded there (a parked sprite is not compute) but its sprite is very
    # much alive at sprites.dev, and a suspended tenant must not keep it.
    from(s in Sandbox,
      where: s.user_id == ^user_id and s.status in ~w(pending starting ready suspended),
      select: s.id
    )
    |> Fountain.Repo.all()
    |> Enum.count(&reaped?/1)
  end

  # A refusal is named here as well as inside `Machine.destroy/2`, and that is
  # the point: the warning the protocol logs carries the machine id, and what
  # an operator needs after a suspension that did not take everything down is
  # the sandbox this tenant still has running. Nothing retries it — this runs
  # once, from `Accounts.suspend_user/1`, the refused row keeps a live status
  # with no fence on it (so `sweep_fenced_teardowns/0` cannot see it), and with
  # the default `SANDBOX_MAX_LIFETIME_HOURS=0` the only pass that will touch it
  # again *parks* it. So the log line is the whole trail, and it says which row.
  defp reaped?(sandbox_id) do
    case reap_sandbox(sandbox_id) do
      {:ok, _outcome} ->
        true

      {:error, reason} ->
        Logger.warning(
          "suspension: sandbox #{sandbox_id} was not reaped (#{inspect(reason)}); " <>
            "it is still running and nothing will retry it"
        )

        false
    end
  end

  @doc """
  Finish an actor's termination only while the conversation is still bound to
  its sandbox. The binding check and status write are one database statement,
  so a reassignment during provider cleanup cannot terminate the new binding.

  The actor owns both IDs. This is internal lifecycle bookkeeping; the public
  `terminate_conversation/2` above records the action's audit once after a
  successful reply. A missing or moved conversation returns a refusal.
  """
  def _unsafe_finish_conversation_termination(conversation_id, sandbox_id) do
    query =
      from(c in Conversation,
        where: c.id == ^conversation_id and c.sandbox_id == ^sandbox_id,
        select: c
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(query, set: [status: "terminated", updated_at: now]) do
      {1, [conv]} ->
        Conversations.broadcast_sidebar_update(conv.user_id)
        {:ok, conv}

      {0, _} ->
        {:error, :sandbox_unavailable}
    end
  end

  # Records a lifecycle action against the conversation's owner.
  #
  # Only on success: an attempt against a conversation that is not running
  # changed nothing, and a trail that logged it would show terminations that
  # never happened.
  #
  # `audit: false` suppresses the row where a caller's own higher-level event
  # already describes the action — `delete_conversation/2` and account
  # deletion both cascade through `terminate/2`, and neither is a second thing
  # the user asked for.
  #
  # The `_unsafe_` read is legitimate here under the rule in CLAUDE.md: these
  # are GenServer client functions, reached only after a tenant-scoped fetch
  # established ownership at the controller or LiveView, and the read exists
  # solely to attribute the event to that same owner.
  def audit_lifecycle(conv_id, action, result, opts, metadata \\ %{}) do
    if Keyword.get(opts, :audit, true) and result == :ok do
      case Conversations._unsafe_get_conversation(conv_id) do
        nil ->
          :ok

        conv ->
          Fountain.Audit.record(%{
            user_id: conv.user_id,
            action: action,
            resource_type: "conversation",
            resource_id: conv_id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: metadata
          })
      end
    end

    :ok
  end
end
