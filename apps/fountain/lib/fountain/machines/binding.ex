defmodule Fountain.Machines.Binding do
  @moduledoc """
  One binding protocol for one machine (ADR 0058, stage 8b).

  A conversation is a binding of an agent to a machine (#805), and the owner
  of the machine is the one that makes and unmakes bindings. ADR 0058's verb
  table gives it `attach` and `detach` as the replacement for the attach door,
  release and `_unsafe_sandbox_held_by_other?/2`, and `retarget` as the
  replacement for `Reapply`'s row write. This module is those three, and the
  fourth thing the binding needs — the machine's Codex auth binding, which
  `InferenceBinding.compatible_machine/2` used to decide and write on its own.
  `Fountain.Machines.Machine.attach/3`, `detach/2`, `retarget/3` and
  `bind_inference/2` are the doors.

  ## The refcount is the rows

  Who is bound to a machine is the conversation rows on it that are not
  terminal, read through `Fountain.Machines.Occupancy.bindings/1` — the one
  reading of "is anyone here" since stage 4 — and never a counter anybody
  maintains. That is the second door of every binding change (rule 16): a
  conversation that ends *without* a detach — deleted, or failed by its
  provision, or written terminal by a sweep — stops counting the moment its
  row is terminal, and the next detach, park or idle verdict sees a machine
  with one fewer conversation on it. Nothing leaks because nothing was ever
  incremented. `held_by_other?/2` is that reading for the one caller that has
  to make it on its own connection.

  ## Attach

  `attach/3` is `Launch.create_attached_conversation/3` as it was on `main`,
  moved here whole: one transaction under the per-sandbox advisory lock (4316)
  that locks the tenant's inference source, re-reads the agent and the
  machine's row, decides `attachable/5` **under that lock** (#2307 constraint
  1), inserts the conversation, reserves its inference and inserts its
  execution allowance. What stage 8b changes is who may call it and where it
  runs: `Fountain.Team.open_fresh_conversation/3` used to insert a bound row
  through `Conversations.create_conversation/1` with none of these checks, and
  with `MACHINE_OWNER_ENABLED` on the write queues in the owner's mailbox
  behind a park, a resume or a destroy of the same machine instead of being
  refused at the door on the lease those hold (stage 6a's rule, unchanged with
  the gate off: a live lease is `:sandbox_unavailable` at once, no wait —
  an attach is a request, and 6a priced the immediate 503 with its
  `Retry-After` against a wait nobody asked for).

  **A late attach is refused, not run** (rule 17, from stage 8a round 1). A
  `GenServer.call` that times out leaves its message in the mailbox, and an
  attach that ran late would be a conversation row for a request already
  told 503. So the owner's message carries the caller's deadline on the
  database clock, `Machine` refuses an expired one before running it, and the
  transaction refuses it again against the `statement_timestamp()` it read
  the machine's row with. What the second check bounds is the row read: a
  commit can still land one transaction tail after the deadline.

  ## Detach

  `detach/2` is the last-detach decision: whether the machine survives the
  conversation that is ending. It is `Lifecycle.fence_sandbox_for_teardown/2`
  with a `terminating_conversation_id`, which is the decision `main` made in
  the same place — `Fountain.Machines.Policy.keep_on_last_detach?/2` over the
  mode and the refcount, under the lock, closing the attach door in the same
  transaction when the machine is going — with two things it did not do:

    * it **refuses a live lease** (`:machine_busy`, waited out for
      `busy_wait_ms/0` and then `:sandbox_unavailable` at the door). `main`
      fenced a machine underneath a park in flight and then found the destroy
      refused, which terminated the conversation and left a fenced row for
      the hourly sweep to finish. Under the owner, a terminate that meets an
      operation waits for it (in the mailbox, with the gate on) or is told to
      come back (with it off), and nothing is written until it does.
    * it **carries a deadline**, for the reason attach does: a fence written
      for a caller that has been told 503 closes a machine to admission with
      a server still serving on it.

  `{:ok, :kept}` is the policy keeping the machine: a persistent home, or an
  ephemeral machine another conversation still holds. `{:ok, :detached}` is
  the fence committed and the machine this caller's to finish — a live
  `ConversationServer` closes its adapter and then asks `Machine.destroy/2`
  with `terminating_conversation_id: nil`, exactly as it did on `main`, so a
  rebind landing between the two cannot turn the second decision into
  `:sandbox_kept` (`termination_actor_fence_test.exs` pins that order). A
  caller with no adapter to close passes `destroy: true` and the protocol
  runs `Fountain.Machines.Destroy` itself, answering `{:ok, :destroyed}`.

  `policy: :keep` is a **release**: the conversation ends and the machine is
  kept whatever the refcount says, which is how a teammate hands its computer
  to a successor (`Fountain.Team.open_fresh_conversation/3`). It writes the
  conversation's row through `Termination._unsafe_release_conversation/2`
  and touches no machine state, so it runs inline whichever way the gate is
  set — `end_turn/3`'s reason: queueing a conversation write behind a
  cotenant's minute-long park buys no serialisation the parent lock does not
  already give, and a timeout there leaves a caller with nothing to retry
  against. The refcount sees it on its next reading, as it sees any terminal
  row.

  ## Retarget

  `retarget/3` is the one write of the machine's binding identity — `agent_id`,
  `environment_id`, `vault_id` — and of `applied_skills`, the record of what
  the disk carries. Two callers: `Reapply.update_identity/4` moves the identity
  with the conversation it reconfigured (#1565), and `Reapply.mount_skills/3`
  records what the skills reconciliation just put on the disk. Refused, under
  the lock, on the two conditions ADR 0023's 2026-09-11 amendment names: a
  co-tenant that declares another identity (`{:rebuild_required,
  :shared_sandbox}` — skills, instructions and `.mcp.json` sit at per-machine
  paths, so reconfiguring a shared machine reconfigures it for everyone on it),
  and a `build_fingerprint` that is not the one the caller expects
  (`{:rebuild_required, :environment}` — the disk was built from other inputs;
  `Reapply.check/2` names the field before this backstop is reached).

  It runs **inline whichever way the gate is set**, and inside the caller's
  transaction when there is one: `Reapply.reapply_conversation/3` holds 4316
  across the conversation's write and this one so that a turn cannot be
  admitted between them, and a hop through the owner process would have the
  owner's own transaction wait on that lock while the caller waits on the
  reply. Without an enclosing transaction it takes the lock itself.

  ## The Codex auth binding

  `bind_inference/2` is `InferenceBinding.compatible_machine/2`, moved. It
  runs inside `InferenceBinding.with_current/2`'s transaction, under 4316 and
  the tenant's source lock, and decides whether the source a conversation is
  reserving is compatible with the machine's recorded `codex_inference_source`
  and with every Codex peer's, then records it. The peers are **every**
  conversation the machine has had, retired ones included — the machine keeps
  its auth binding through a conversation's termination, because a detached
  runtime may survive its actor and only a new machine can change that binding
  — so this is the one reading here that is deliberately *not*
  `Occupancy.bindings/1`, whose answer is who holds the machine now. It is read
  on **this** connection rather than through `Machine.who_is_here/1` for the
  #2348 reason as well: the call sits inside an advisory-locked transaction
  whose own uncommitted rows are the ones being bound.

  ## Vocabulary

  Every answer here is a word the callers already handled on `main`:
  `attach/3` answers the attach door's (`:sandbox_identity_mismatch`,
  `:sandbox_runtime_mismatch`, `:sandbox_reset_pending`,
  `{:sandbox_not_attachable, status}`, `:sandbox_unavailable`, `:not_found`, a
  changeset, the inference and allowance refusals); `detach/2` the fence's and
  the release's; `retarget/3` the reapply's. New are `:machine_busy` (a live
  lease, waited out), `:attach_expired` / `:detach_expired` (a caller that
  left) and `:transaction_open` (the caller's bug), which the door translates.
  """

  import Ecto.Query

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ExecutionAllowance, Sandbox}
  alias Fountain.Conversations.{InferenceBinding, Launch, Lifecycle, Termination}
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Occupancy
  alias Fountain.Repo

  require Logger

  # Must match `Fountain.Conversations`' own `@sandbox_lock_namespace`; module
  # attributes do not cross a module boundary, so every taker of this lock
  # writes the same integer.
  @sandbox_lock_namespace 4316

  # How long a *detach* waits for a live lease to clear before it is refused.
  # `Destroy`'s number, for `Destroy`'s reason: the caller is a request (a
  # `DELETE` on the dead-server path, a `ConversationServer`'s `handle_call` on
  # the live one) and a wait that outlives it answers nobody.
  #
  # **With the gate on, this wait is the owner's mailbox**, not just the
  # caller's: the detach runs inside `Machine`'s `handle_call`, so everything
  # queued behind it waits too. Against a real operation that is the point —
  # the queue is how two callers on one machine are serialized — but against a
  # lease a crashed operation on *this* node left behind, it is five seconds
  # of the owner spent on a lease nobody will release, and the early door
  # (`Lease.absent_node_headroom_ms/0`) cannot help, because it only judges a
  # holder whose node is gone and this node is here (round 1, protocol review:
  # `waited ms: 4809`). Bounded, rare, and the same shape as 8a's "one queued
  # cotenant park lost per owner crash"; the standing fix is the renew timer
  # ending with its operation, which is stage 7a's and already in place for
  # every operation that exits cleanly.
  @busy_wait_ms 5_000

  # How often the wait re-asks. Each ask is the whole fence transaction.
  @poll_ms 250

  @terminal_statuses ~w(terminated failed)
  @attachable_statuses ~w(ready suspended)

  # The columns a retarget may write, and nothing else. `status` and the
  # transition are `Lease.cas_update/3`'s under an epoch; the fences are the
  # fence's; the rest of the row is the provision's.
  @retargetable ~w(agent_id environment_id vault_id applied_skills)a
  @identity ~w(agent_id environment_id vault_id)a

  @typedoc "What a detach did."
  @type detach_outcome :: :kept | :detached | :destroyed | :already_terminal | :released

  # ── attach ────────────────────────────────────────────────────────────────

  @doc """
  Bind a new conversation to the machine behind `sandbox_id`.

  `attrs` is the conversation row, as `Conversation.changeset/2` takes it; it
  must carry `:sandbox_id` (equal to `sandbox_id`), `:agent_id`, `:user_id`,
  `:vault_id` and `:environment_id`. Options:

    * `:request` — the execution-limits request, resolved under the lock by
      `Conversations.resolve_admission_limits/2`; nil for the account's default.
    * `:rotate_from` — a channel rotation, handed to
      `Launch.unbind_rotated_channel/2` inside the transaction.
    * `:actor` / `:request_ip` — attribution for the allowance event.
    * `:deadline` — a `DateTime` on the database clock after which the caller
      is no longer waiting. Set by `Machine.attach/3` on the in-owner path.

  Answers `{:ok, conversation, allowance}` after the commit, having fired the
  two effects every conversation insert owes: `Conversations.after_conversation_created/1`
  and the allowance's audit event.
  """
  @spec attach(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Conversation.t(), struct()} | {:error, term()}
  def attach(sandbox_id, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_map(attrs) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      case Repo.transaction(fn -> locked_attach(sandbox_id, attrs, opts) end) do
        {:ok, {conv, allowance}} ->
          Conversations.after_conversation_created(conv)
          Conversations.record_execution_allowance_created(allowance, conv.user_id, opts)
          {:ok, conv, allowance}

        {:error, _} = error ->
          error
      end
    end
  end

  # `main`'s `Launch.create_attached_conversation/3`, line for line where the
  # order matters: the source lock before the machine lock (the ordering
  # `reserve_initial_conversation/4` established and `lock_order_test.exs`
  # pins), the tenant and the agent re-read, the rotation unbind, then the
  # machine's row and the decision on it.
  defp locked_attach(sandbox_id, attrs, opts) do
    if attrs.sandbox_id != sandbox_id, do: Repo.rollback(:not_found)

    :ok = InferenceCredentials.lock_source(attrs.user_id)

    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @sandbox_lock_namespace,
      :erlang.phash2(sandbox_id)
    ])

    # Deliberately unlocked. `users` is the row every credit posting takes
    # `FOR UPDATE` (`Credits.insert_and_move/3` holds it across a ledger
    # insert, lot consumption and the balance move), so locking it here would
    # park admission behind an unrelated billing transaction. This read is an
    # ownership recheck; the insert's foreign keys enforce integrity.
    Repo.one(from u in Fountain.Accounts.User, where: u.id == ^attrs.user_id, select: u.id) ||
      Repo.rollback(:not_found)

    agent =
      Repo.one(
        from a in Agents.Agent,
          where: a.id == ^attrs.agent_id and a.user_id == ^attrs.user_id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

    case Launch.unbind_rotated_channel(attrs, opts) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # The clock rides along with the locked read, as it does in
    # `Lease.claim/4` and the turn admission: the lease and the deadline are
    # both judged at the instant the row was seen.
    {sandbox, now} =
      Repo.one(
        from s in Sandbox,
          where: s.id == ^sandbox_id and s.user_id == ^attrs.user_id,
          select: {s, fragment("statement_timestamp()")},
          lock: "FOR NO KEY UPDATE"
      ) || Repo.rollback(:not_found)

    case attachable(sandbox, agent, attrs.vault_id, attrs.environment_id, now) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # After the machine's own verdicts, so a refusal names the machine first;
    # before the write, so an expired caller gains nothing.
    if expired?(Keyword.get(opts, :deadline), now), do: Repo.rollback(:attach_expired)

    with {:ok, limits} <-
           Conversations.resolve_admission_limits(attrs.user_id, Keyword.get(opts, :request)),
         {:ok, conv} <- Conversations.insert_conversation_row(attrs),
         :ok <- reserve_inference(conv),
         {:ok, allowance} <-
           conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert() do
      {conv, allowance}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A conversation whose admission resolved no inference source — a teammate's
  # successor, which inherits the machine's binding on its first prompt —
  # reserves none; `Launch.attach_conversation/3` always resolves one.
  defp reserve_inference(%Conversation{inference_source: nil}), do: :ok

  defp reserve_inference(%Conversation{} = conv),
    do: InferenceBinding.reserve(conv, Source.load(conv.inference_source))

  @doc """
  May a conversation of `agent` with this vault and environment attach to
  `sandbox`?

  The attach door's rule, as `Launch.check_attachable/4` had it: the fence
  first (409, the most specific answer) — the reset column, and since stage 9a
  the `destroying` stamp that will outlive it — then the status, then the three
  permanent refusals — identity, identity, runtime — and last the transient
  one, a live lease. That order is the contract (stage 6a round 1): a permanent
  no outranks a temporary one, so an identity-mismatched attach onto a busy
  machine is 422 rather than a 503 telling the caller to retry something that
  will never work.

  `now` is the clock the lease is judged against; a caller holding the row
  under a lock passes the `statement_timestamp()` it read it with, and the
  pre-lock check in `Launch` lets it default. The verdict a caller takes
  before the lock is a courtesy to the person waiting; the one inside
  `attach/3` is the decision.
  """
  @spec attachable(Sandbox.t(), Agents.Agent.t(), String.t() | nil, String.t() | nil, term()) ::
          :ok | {:error, term()}
  def attachable(sandbox, agent, vault_id, env_id, now \\ :db)

  def attachable(%Sandbox{reset_requested_at: at}, _agent, _vault_id, _env_id, _now)
      when not is_nil(at),
      do: {:error, :sandbox_reset_pending}

  # The same fence read off the stamp, which is where it lives once stage 9b
  # drops the column above (ADR 0058 stage 9a). Refused whatever the lease
  # says, and before the status clause for the reason the reset fence is:
  # `destroying` on a live row is a machine somebody asked to be destroyed, and
  # an owner that died mid-destroy did not withdraw the request. A terminal row
  # never reaches here wearing a stale stamp either — `{:sandbox_not_attachable,
  # status}` below is the more useful answer and this clause hands it on.
  def attachable(%Sandbox{transition: "destroying", status: status}, _agent, _v, _e, _now)
      when status in @attachable_statuses,
      do: {:error, :sandbox_reset_pending}

  def attachable(%Sandbox{status: status}, _agent, _vault_id, _env_id, _now)
      when status not in @attachable_statuses,
      do: {:error, {:sandbox_not_attachable, status}}

  def attachable(%Sandbox{} = sandbox, %Agents.Agent{} = agent, vault_id, env_id, now) do
    cond do
      sandbox.agent_id != agent.id ->
        {:error, :sandbox_identity_mismatch}

      sandbox.vault_id != vault_id ->
        {:error, :sandbox_identity_mismatch}

      sandbox.environment_id != (env_id || agent.environment_id) ->
        {:error, :sandbox_identity_mismatch}

      # The disk was shaped by the runtime that first ran on it; an agent
      # whose runtime changed since gets a new machine, not this one.
      newest_runtime(sandbox.id) not in [nil, agent.runtime] ->
        {:error, :sandbox_runtime_mismatch}

      # An owner holds a live lease (stage 6a): a destroy, a reset, a park or
      # a resume between its intent and its finalize. Last, after every
      # permanent refusal. Nothing terminal reaches here — the status clause
      # took it.
      Lease.live?(sandbox, now) ->
        {:error, :sandbox_unavailable}

      true ->
        :ok
    end
  end

  # The runtime of the newest conversation on the machine, or nil when it has
  # none. `Launch._unsafe_sandbox_runtime/1` until stage 8b.
  defp newest_runtime(sandbox_id) do
    Repo.one(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 1,
        select: c.runtime
    )
  end

  # ── detach ────────────────────────────────────────────────────────────────

  @doc """
  End `opts[:conversation_id]`'s binding to the machine behind `sandbox_id`.

  Options:

    * `:conversation_id` (required) — the conversation that is ending.
    * `:policy` — `:mode` (the default) applies the mode's last-detach rule
      through the teardown fence; `:keep` is a release, which keeps the machine
      whatever the rule says and writes only the conversation's row.
    * `:destroy` — with `:mode`, `true` runs `Fountain.Machines.Destroy` in
      the same call once the fence has committed and answers `{:ok, :destroyed}`;
      `false` (the default) answers `{:ok, :detached}` and leaves the destroy
      to the caller, which is what a live server with an adapter to close
      first needs.
    * `:actor`, `:reason`, `:fence_reason`, `:destroy_reason`, `:request_ip`,
      `:metadata`, `:audit` — attribution, as `Termination._unsafe_destroy_machine/2`
      takes them. `:reason` is the fence's own event string
      (`"conversation_terminated"` by default); `:destroy_reason` the atom the
      destroy stamps and records (`:terminated` by default).
    * `:actor_alive?` — with `:keep`, whether a server is driving the
      conversation; a running turn refuses a release only when one is.
    * `:deadline` — as `attach/3`'s.
    * `:busy_wait_ms` — the bound above. Tests shorten it; no call site does.
  """
  @spec detach(Ecto.UUID.t(), keyword()) :: {:ok, detach_outcome()} | {:error, term()}
  def detach(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    cond do
      Repo.in_transaction?() ->
        {:error, :transaction_open}

      Keyword.get(opts, :policy, :mode) == :keep ->
        release(conversation_id, opts)

      true ->
        deadline =
          System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

        fence_then_finish(sandbox_id, conversation_id, opts, deadline)
    end
  end

  @doc """
  How long `detach/2` waits for a live lease to clear before refusing.

  Public so `machine_bounds_test.exs` can pin it against the owner's call
  timeout above it.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  defp release(conversation_id, opts) do
    case Termination._unsafe_release_conversation(
           conversation_id,
           Keyword.take(opts, [:actor_alive?])
         ) do
      :ok -> {:ok, :released}
      {:error, _} = error -> error
    end
  end

  # The fence with the ending conversation is the decision; `:machine_busy` is
  # the one refusal waited out, because a park or a resume settles in seconds
  # and the terminate wants its answer rather than a 503.
  defp fence_then_finish(sandbox_id, conversation_id, opts, wait_until) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :sandbox_unavailable}

      %Sandbox{status: status} when status in @terminal_statuses ->
        {:ok, :already_terminal}

      %Sandbox{} = sandbox ->
        case Lifecycle.fence_sandbox_for_teardown(sandbox, fence_opts(conversation_id, opts)) do
          {:ok, %Sandbox{status: status}} when status in @terminal_statuses ->
            {:ok, :already_terminal}

          {:ok, %Sandbox{}} ->
            finish(sandbox_id, opts)

          {:error, :sandbox_kept} ->
            {:ok, :kept}

          {:error, :machine_busy} ->
            if System.monotonic_time(:millisecond) + @poll_ms < wait_until do
              Process.sleep(@poll_ms)
              fence_then_finish(sandbox_id, conversation_id, opts, wait_until)
            else
              Logger.warning("machine #{sandbox_id}: detach refused, an owner holds the lease")
              {:error, :machine_busy}
            end

          {:error, _} = error ->
            error
        end
    end
  end

  defp fence_opts(conversation_id, opts) do
    [
      terminating_conversation_id: conversation_id,
      refuse_busy: true,
      actor: Keyword.get(opts, :actor, "self"),
      reason: Keyword.get(opts, :reason, "conversation_terminated"),
      # The row's word, which is the destroy vocabulary and not this event's.
      # The same default `destroy_opts/1` below hands the protocol, so a detach
      # that fences and then destroys stamps once and says one thing — and an
      # abandoned one hands `SandboxReaper`'s driver the reason the caller
      # actually asked for rather than a generic teardown.
      transition_reason: Keyword.get(opts, :destroy_reason, :terminated)
    ]
    |> put_unless_nil(:request_ip, Keyword.get(opts, :request_ip))
    |> put_unless_nil(:metadata, Keyword.get(opts, :metadata))
    |> put_unless_nil(:deadline, Keyword.get(opts, :deadline))
  end

  # Fenced, and the machine is going. With `destroy: true` this call finishes
  # it, and the protocol does not fence again: the fence above stamped
  # `transition: "destroying"` (stage 9a), so `Destroy.run/2` continues from
  # the stamp. Before 9a it repeated the fence, which wrote no second intent
  # and — with the `terminating_conversation_id: nil` below — could not reopen
  # the decision just made either. The `nil` stays for that reason and for the
  # one `destroy_opts/1` gives.
  defp finish(sandbox_id, opts) do
    if Keyword.get(opts, :destroy, false) do
      case Destroy.run(sandbox_id, destroy_opts(opts)) do
        {:ok, :destroyed} -> {:ok, :destroyed}
        {:ok, :already_terminal} -> {:ok, :already_terminal}
        # Unreachable without a terminating conversation, and answered as the
        # fence's own `:kept` would be if it were.
        {:ok, :kept} -> {:ok, :kept}
        {:error, :superseded} -> {:ok, :already_terminal}
        {:error, _} = error -> error
      end
    else
      {:ok, :detached}
    end
  end

  defp destroy_opts(opts) do
    [
      actor: Keyword.get(opts, :actor, "self"),
      reason: Keyword.get(opts, :destroy_reason, :terminated),
      fence_reason: Keyword.get(opts, :reason, "conversation_terminated"),
      terminating_conversation_id: nil,
      audit: Keyword.get(opts, :audit, true)
    ]
    |> put_unless_nil(:request_ip, Keyword.get(opts, :request_ip))
    |> put_unless_nil(:metadata, Keyword.get(opts, :metadata))
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Whether a conversation other than `conv_id` still holds `sandbox_id` — one
  that is not `terminated` or `failed`. Status only, no clock; the refcount
  the last-detach rule is decided on.

  `Lifecycle._unsafe_sandbox_held_by_other?/2` until stage 8b, and still a
  plain function over the rows rather than a question for the owner process:
  its one caller is the teardown fence, which asks inside its own
  advisory-locked transaction about rows that transaction has written and not
  yet committed (#2348 review). The caller has established ownership of
  `conv_id`.
  """
  @spec held_by_other?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def held_by_other?(sandbox_id, conv_id) when is_binary(sandbox_id) and is_binary(conv_id) do
    sandbox_id |> Occupancy.bindings() |> Occupancy.held_by_other?(conv_id)
  end

  # ── retarget ──────────────────────────────────────────────────────────────

  @doc """
  Move the machine's binding identity, or its skills record, to `attrs`.

  `attrs` names any of `agent_id`, `environment_id`, `vault_id` and
  `applied_skills`; anything else is `{:error, {:invalid, field}}`. Options:

    * `:expected_fingerprint` — the `build_fingerprint` the caller decided on;
      a row that carries another is `{:error, {:rebuild_required, :environment}}`.
      Omitted by a caller that is not moving the identity.

  Refused with `{:error, {:rebuild_required, :shared_sandbox}}` when the
  identity moves and a co-tenant still declares the old one; with
  `{:error, :sandbox_unavailable}` on a terminal or missing row. A move onto
  a persistent home that already exists is the changeset's `:home` error, as
  it was through `Conversations.update_sandbox/2`.

  Runs inside the caller's transaction when there is one (see the moduledoc),
  and under the machine's advisory lock otherwise.
  """
  @spec retarget(Ecto.UUID.t(), map(), keyword()) :: {:ok, Sandbox.t()} | {:error, term()}
  def retarget(sandbox_id, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_map(attrs) and is_list(opts) do
    with :ok <- validate_retarget(attrs) do
      if Repo.in_transaction?() do
        locked_retarget(sandbox_id, attrs, opts)
      else
        Conversations.with_sandbox_lock(sandbox_id, fn ->
          locked_retarget(sandbox_id, attrs, opts)
        end)
      end
    end
  end

  defp validate_retarget(attrs) when map_size(attrs) == 0, do: {:error, {:invalid, :attrs}}

  defp validate_retarget(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @retargetable)) do
      nil -> :ok
      field -> {:error, {:invalid, field}}
    end
  end

  defp locked_retarget(sandbox_id, attrs, opts) do
    current = Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, lock: "FOR UPDATE")

    cond do
      is_nil(current) or current.status in @terminal_statuses ->
        {:error, :sandbox_unavailable}

      moves_identity?(current, attrs) and shared?(current, Keyword.get(opts, :conversation_id)) ->
        {:error, {:rebuild_required, :shared_sandbox}}

      fingerprint_changed?(current, Keyword.get(opts, :expected_fingerprint)) ->
        {:error, {:rebuild_required, :environment}}

      true ->
        current |> Sandbox.changeset(attrs) |> Repo.update()
    end
  end

  defp moves_identity?(%Sandbox{} = current, attrs) do
    Enum.any?(@identity, fn field ->
      Map.has_key?(attrs, field) and Map.fetch!(attrs, field) != Map.fetch!(current, field)
    end)
  end

  # The co-tenant rule: another conversation on the machine that is not the
  # one being reconfigured. The identity every conversation on a machine was
  # pinned to at its attach is the machine's, so any co-tenant declares the
  # one this move is leaving.
  defp shared?(%Sandbox{id: sandbox_id}, nil),
    do: sandbox_id |> Occupancy.bindings() |> Map.fetch!(:bound) != []

  defp shared?(%Sandbox{id: sandbox_id}, conv_id), do: held_by_other?(sandbox_id, conv_id)

  defp fingerprint_changed?(_current, nil), do: false
  defp fingerprint_changed?(%Sandbox{build_fingerprint: fp}, expected), do: fp != expected

  # ── the Codex auth binding ────────────────────────────────────────────────

  @doc """
  Record `source` as the machine's Codex auth binding for `conv`, if it is
  compatible with what the machine and its Codex co-tenants already carry.

  `InferenceBinding.compatible_machine/2` until stage 8b, unchanged in what it
  decides: a machine still being built takes any source; a built one takes a
  source whose kind, identity and revision match its recorded binding, and only
  if every Codex co-tenant's does too. Legacy peers without a binding are
  incompatible. Must be called inside `InferenceBinding.with_current/2`'s
  transaction — this is the one protocol entry point that *requires* an
  enclosing transaction rather than refusing one, because the row it binds is
  locked there.

  **What the guard actually checks is weaker than that sentence**, and it is
  worth saying so (round 1, protocol review). `Repo.in_transaction?/0` sees a
  transaction, not *which* transaction: a plain `Repo.transaction/1` holding
  neither the user's source lock nor the sandbox's 4316 passes it and runs. The
  guard is not what makes two concurrent binds correct — the `FOR NO KEY
  UPDATE` this function takes on the machine's own row is, and it is taken
  here rather than assumed. What `with_current/2` adds on top is the ordering
  with turn admission, reapply and teardown, which all take 4316 first.

  Asserting 4316 itself would mean reading `pg_locks` for this backend on every
  Codex bind, which is a round trip on the admission path to catch a caller
  that does not exist: `InferenceBinding` is this function's only caller, and
  `machines/lock_order_test.exs` is what keeps a second one honest. So: a
  convention the code can only half see, said out loud rather than enforced.
  """
  @spec bind_inference(Conversation.t(), Source.t()) ::
          :ok | {:error, :codex_inference_conflict | :sandbox_not_found | :transaction_required}
  def bind_inference(%Conversation{runtime: runtime}, _source) when runtime != "codex", do: :ok

  def bind_inference(%Conversation{} = conv, %Source{} = source) do
    if Repo.in_transaction?() do
      locked_bind_inference(conv, source)
    else
      {:error, :transaction_required}
    end
  end

  defp locked_bind_inference(conv, source) do
    sandbox =
      Repo.one(
        from s in Sandbox,
          where: s.id == ^conv.sandbox_id and s.user_id == ^conv.user_id,
          lock: "FOR NO KEY UPDATE"
      )

    if sandbox do
      peers = codex_peer_sources(sandbox.id, conv.id)
      dumped = Source.dump(source)
      fresh? = sandbox.status in ["pending", "starting"]

      if ((is_nil(sandbox.codex_inference_source) and fresh?) or
            compatible?(sandbox.codex_inference_source, dumped)) and
           Enum.all?(peers, &compatible?(&1, dumped)) do
        sandbox
        |> Ecto.Changeset.change(codex_inference_source: dumped)
        |> Repo.update!()

        :ok
      else
        {:error, :codex_inference_conflict}
      end
    else
      {:error, :sandbox_not_found}
    end
  end

  # Every Codex conversation the machine has carried, the retired ones too —
  # see the moduledoc on why this is not the refcount's reading.
  defp codex_peer_sources(sandbox_id, conv_id) do
    Repo.all(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id and c.id != ^conv_id and c.runtime == "codex",
        select: c.inference_source
    )
  end

  defp compatible?(nil, _), do: false

  defp compatible?(left, right),
    do: Map.take(left, ~w(kind identity revision)) == Map.take(right, ~w(kind identity revision))

  # ── the deadline ──────────────────────────────────────────────────────────

  @doc false
  def expired?(nil, _now), do: false

  def expired?(%DateTime{} = deadline, %DateTime{} = now),
    do: DateTime.compare(now, deadline) == :gt
end
