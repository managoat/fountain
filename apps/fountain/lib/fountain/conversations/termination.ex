defmodule Fountain.Conversations.Termination do
  @moduledoc """
  The client half of terminate and release: what a caller does to end a
  conversation, whether or not its `ConversationServer` is alive.

  Moved out of `Fountain.Conversations.ConversationServer` and
  `Fountain.Conversations.Lifecycle` in #2209 (one owner per lifecycle verb,
  #2175). The server keeps the actor halves — `handle_call({:terminate_conv, ..})`,
  `handle_call(:release_conv)`, `terminate_machine`, `terminate_kept_machine`,
  `finish_termination` and OTP `terminate/2` — because each needs
  `state.handle` or orders a row write against the reply. Everything here is a
  function over a conversation id, the registry and rows.

  This module also owns the terminated and released rows themselves
  (`_unsafe_release_conversation/2`, `_unsafe_finish_conversation_termination/2`,
  moved from `Fountain.Conversations` in #2268), the same way
  `Fountain.Conversations.Interruption` owns the interrupted turn row
  (#2244). The machine fence a forced teardown refuses or commits against is
  `Fountain.Conversations.Lifecycle`'s (#2258) — a rule about the sandbox,
  not a conversation verb; this module calls it, it does not own it.

  Tenant scoping is the caller's job: every public function here is reached
  after a tenant-scoped fetch established ownership at the controller,
  `Fountain.Team`, `Fountain.Accounts.Deletion` or a system sweep, exactly as
  when these lived on the server. `ConversationServer.terminate_conversation/2`
  and `release_conversation/2` delegate here so no caller moved.
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
      # ownership: callers established this conversation's tenant. Cleanup must
      # survive a blocked actor, failed provider teardown, or subsequent deletion.
      case Fountain.Conversations.ExecutionGuard._unsafe_interrupt(conv_id) do
        {:ok, _} -> terminate_after_journal_interrupt(conv_id, opts)
        {:error, :not_found} -> {:error, :not_running}
        {:error, _} = error -> error
      end
    end
  end

  defp terminate_after_journal_interrupt(conv_id, opts) do
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
          call_server(pid, {:terminate_conv, Keyword.take(opts, [:actor, :request_ip])})
      end

    audit_lifecycle(conv_id, "conversation.terminated", result, opts)
    result
  end

  @doc """
  End the conversation but keep its computer: the conversation goes
  `terminated` (past resuming, its transcript intact), the sandbox row and
  the sprite behind it are left exactly as they are, and this server stops
  holding them. The callback key this server minted is revoked on the way
  out (`terminate/2`), so nothing on the sandbox can act as the retired
  conversation.

  This is how a teammate starts a fresh conversation on the same computer
  (`Fountain.Team.open_fresh_conversation/3`): the successor conversation
  takes the `sandbox_id`, and its first prompt reattaches through the
  ordinary wake path — a new runtime session on the same disk.

  `{:error, :busy}` while a turn runs on a **live** server; nothing is
  interrupted. With no server alive that row is as likely an orphan (see
  `Conversations.wake_for_interrupt/1`), so release proceeds. Unresolved
  bounded execution answers `{:error, :execution_fenced}` either way: a
  durable fact rather than an inference, and bounded (ADR 0046).

  Audited as `conversation.released` unless `audit: false`.
  """
  def release_conversation(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          # ownership: established by the caller before release_conversation/2.
          _unsafe_release_conversation(conv_id, actor_alive?: false)

        pid ->
          call_server(pid, :release_conv)
      end

    audit_lifecycle(conv_id, "conversation.released", result, opts)
    result
  end

  @doc """
  Commit the teardown fence for a conversation that is ending, on behalf of
  its live `ConversationServer`.

  `_unsafe_`: it takes a bare `sandbox_id` and writes the row and an audit
  event with no tenant scoping of its own (`contributing/server.md`). Its
  ownership is the caller's — a `ConversationServer` that established this
  conversation and its sandbox at `init/1` — which used to be visible from the
  fact that the function lived on the server. Prefixed now that it does not.

  The decision the server needs *before* it closes its adapter: `{:ok,
  sandbox}` to tear the machine down, `{:error, :sandbox_kept}` to leave it
  standing for a home or a co-tenant. The fence itself is
  `Fountain.Conversations.Lifecycle`'s — a rule about the machine, not a
  conversation verb — and `_unsafe_destroy_machine/2` below repeats it idempotently
  when it runs, so this is a pre-check, not the fence of record.

  Ownership is the caller's: the server established this conversation and its
  sandbox at `init/1`, and the conditional fence rechecks the binding under
  the lock anyway.
  """
  @spec _unsafe_fence_machine(String.t() | nil, String.t(), keyword()) ::
          {:ok, Sandbox.t()} | {:error, term()}
  def _unsafe_fence_machine(sandbox_id, conversation_id, opts) do
    opts =
      opts
      |> Keyword.put(:terminating_conversation_id, conversation_id)
      |> Keyword.put_new(:reason, "conversation_terminated")

    # ownership: the caller's server established this conversation and its
    # sandbox at init/1; the conditional fence rechecks the binding under the
    # per-sandbox lock before it commits anything.
    case sandbox_id && Conversations._unsafe_get_sandbox(sandbox_id) do
      nil -> {:error, :sandbox_unavailable}
      sandbox -> Lifecycle.fence_sandbox_for_teardown(sandbox, opts)
    end
  end

  @doc """
  Destroy the machine of a conversation that is ending, through its owner
  (ADR 0058 stage 5).

  `_unsafe_`, for the same reason as `_unsafe_fence_machine/3` above: a bare
  `sandbox_id` and no tenant scoping here. Both callers established the
  conversation this machine belongs to first.

  One door for both halves of terminate — the live server's and the dead
  server's — so the fence, the provider destroy, the terminal write and the
  `sandbox.destroyed` event are the same five steps whichever half ran.

  **`:terminating_conversation_id` says which call's fence decides**, and the
  two halves answer it differently:

    * **the conversation's id**, from the dead-server path, where this fence is
      the first and only look at the machine. A persistent home or a live
      co-tenant then answers `{:ok, :kept}` and nothing is touched — the
      kept-machine semantics this path has always had.
    * **`nil`**, from a live server that already ran `_unsafe_fence_machine/3` and
      acted on its verdict. The protocol still fences — a repeat, which writes
      no second intent and is what keeps a mixed-version fleet safe — but it
      must not decide the binding a second time. By then the turn has been
      interrupted and the adapter closed, and a conversation rebound to another
      machine in between would make the second decision `:sandbox_kept`,
      leaving this machine fenced, live and billing with no server left to
      finish it (`ee/test/.../termination_billing_test.exs` is that race).

  The two reasons are deliberately different words. `:terminated` is the
  machine's transition and what the `sandbox.destroyed` event says happened;
  `"conversation_terminated"` (or whatever the caller passed as `:reason`) is
  what the fence's `sandbox.teardown_requested` event has always said, and
  changing that would rewrite a trail operators already read.
  """
  @spec _unsafe_destroy_machine(String.t(), keyword()) ::
          {:ok, Fountain.Machines.Destroy.outcome()} | {:error, term()}
  def _unsafe_destroy_machine(sandbox_id, opts) do
    Machine.destroy(sandbox_id,
      actor: Keyword.get(opts, :actor, "self"),
      reason: :terminated,
      fence_reason: Keyword.get(opts, :reason, "conversation_terminated"),
      terminating_conversation_id: Keyword.fetch!(opts, :terminating_conversation_id),
      request_ip: Keyword.get(opts, :request_ip)
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
    # caller; the fence inside the protocol rechecks the binding under its lock.
    case Conversations._unsafe_get_sandbox(conv.sandbox_id) do
      nil ->
        {:error, :sandbox_unavailable}

      _sandbox ->
        # Nothing has fenced this machine yet, so the protocol's fence is the
        # decision: it keeps a home or a machine a co-tenant still holds.
        opts = Keyword.put(opts, :terminating_conversation_id, conv.id)

        case _unsafe_destroy_machine(conv.sandbox_id, opts) do
          {:ok, _outcome} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Tear down every home of `agent_id` — what deleting the agent does, since
  the identity the homes were built for is gone (ADR 0023 step 5). Each live
  conversation on a home is terminated (a home survives that on its own), then
  the sprite is destroyed and the row terminated. Best-effort per machine; a
  provider error is logged and the row still retires, so the reaper's sweep
  sees a terminal row rather than a live one nobody can find. Returns the
  number of homes torn down, or a fencing error. Refuses an enclosing database
  transaction before any teardown. Admission is fenced before actor shutdown
  and provider I/O; already admitted turns may be interrupted by this forced
  operation.
  """
  def destroy_homes_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    if Fountain.Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      from(s in Sandbox,
        where:
          s.agent_id == ^agent_id and s.mode == "persistent" and
            s.status not in ["terminated", "failed"]
      )
      |> Fountain.Repo.all()
      |> Enum.reduce_while(0, fn home, count ->
        case destroy_home(home, Keyword.put_new(opts, :reason, "agent_deleted")) do
          :ok -> {:cont, count + 1}
          # A home deleted since the query above is already gone. Keep this
          # idempotence specific to agent deletion; other fence errors still stop it.
          {:error, :not_found} -> {:cont, count}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def destroy_home(%Sandbox{} = sandbox, opts \\ []) do
    if Fountain.Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      # ownership: this sandbox belongs to the agent whose deletion is in
      # progress — established by destroy_homes_for_agent/2's own scoped
      # query above, or by a test's scoped fetch before calling here directly.
      with {:ok, fenced} <- Lifecycle.fence_sandbox_for_teardown(sandbox, opts) do
        fenced = Fountain.Repo.preload(fenced, :conversations)

        # A remote self-call (not a bare local call): Mimic's copy renames the
        # original module's compiled code, so only a call through the module's
        # own name is routed through a stub in test (`forced_home_fence_test.exs`).
        fenced.conversations
        |> Enum.reject(&(&1.status in ["terminated", "failed"]))
        |> Enum.each(&__MODULE__.terminate_conversation(&1.id, actor: "system:home_reset"))

        _unsafe_retire_home(fenced)
      end
    end
  end

  # Destroy the sprite behind a home and retire its row. Best-effort on the
  # provider side: a destroy error is logged and the row still goes
  # `terminated`, so the reaper's sweep sees a terminal row rather than a
  # live one nobody can find. What happens to the conversations on the home
  # is the caller's decision — agent delete terminates them, a reset keeps
  # them.
  #
  # `terminated_at` is deliberately not passed. A caller that already retired
  # the row under its machine lock — `do_reset_sandbox/2` does, so that a
  # bounded registration cannot slip in behind the destroy — keeps the stamp it
  # wrote, and `update_sandbox/2` sees no change to make. A caller that did not
  # gets one from `stamp_terminated_at/1`. Passing `utc_now()` here instead
  # moved the stamp to *after* the provider call, so it disagreed with the
  # `duration_ms` on the `sandbox_terminated` usage row by the length of a
  # destroy — and that row is what a provider bill is reconciled against.
  defp _unsafe_retire_home(%Sandbox{} = sandbox) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("home #{sandbox.machine_name} destroy failed: #{inspect(reason)}")
    end

    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "terminated"})
    :ok
  end

  @doc """
  Support teardown of any tenant's sandbox, from the admin panel. Moved from
  `Fountain.Conversations._unsafe_reap_sandbox/1` in #2257 (#2255, tranche 2).

  A conversation with a live `ConversationServer` is terminated through the
  server, which destroys the sprite and ends the conversation — that is what
  stopping a runaway agent means. A sandbox with no live server (including a
  `suspended` one) just has its row marked terminated: the conversation stays
  resumable (next prompt gets a fresh sandbox, with the agent's memory lost —
  decisions/0017) and the reaper destroys the sprite on its next pass, the
  same split `SandboxReaper.sweep_abandoned_sandboxes/0` uses.

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
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            {:ok, _} =
              Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now})

            {:ok, :released}
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
    # Deliberately NOT Quotas.active_statuses(): `suspended` is excluded from
    # the concurrency cap (a parked sprite is not compute) but its sprite is
    # very much alive at sprites.dev, and a suspended tenant must not keep it.
    from(s in Sandbox,
      where: s.user_id == ^user_id and s.status in ~w(pending starting ready suspended),
      select: s.id
    )
    |> Fountain.Repo.all()
    |> Enum.count(fn id -> match?({:ok, _}, reap_sandbox(id)) end)
  end

  @doc """
  The journal door for `_unsafe_release_conversation/2` below: the same
  durable-idle-parent release `ExecutionGuard._unsafe_release_parent/3`
  performs, exposed so that module is the journal's only caller outside
  `ExecutionGuard` itself. Arguments and return are the guard's, unchanged.
  """
  def release_journal(conversation_id, writer, opts \\ []) do
    # ownership: the caller (_unsafe_release_conversation/2 below) already
    # received an owned conversation id from its own caller.
    Fountain.Conversations.ExecutionGuard._unsafe_release_parent(conversation_id, writer, opts)
  end

  @doc "Terminate the owned conversation only when no turn or remote execution remains open."
  def _unsafe_release_conversation(conversation_id, opts \\ []) do
    # ownership: the lifecycle client/actor received an already-owned conversation.
    result =
      release_journal(
        conversation_id,
        fn current ->
          current |> Conversation.changeset(%{status: "terminated"}) |> Repo.update()
        end,
        opts
      )

    case result do
      {:ok, %{applied: true, conversation: conv}} ->
        Conversations.broadcast_sidebar_update(conv.user_id)

      _ ->
        :ok
    end

    case result do
      {:ok, _} -> :ok
      error -> error
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
