defmodule Fountain.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit

  alias Fountain.Conversations.{
    Blocks,
    Conversation,
    DetachedRequest,
    Labels,
    LogEvent,
    Sandbox,
    Turn,
    TurnImage
  }

  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Termination
  alias Fountain.Conversations.InferenceResolution
  alias Fountain.Conversations.{ExecutionAllowance, ExecutionGuard, ExecutionLimits}
  alias Fountain.Conversations.Lifecycle
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.PermissionPolicy
  alias Fountain.Repo

  # Advisory-lock namespace for per-sandbox machine operations. Distinct from
  # Quotas' per-user reservation (4315): this one is taken inside a turn
  # start, and the two must never be mistaken for one another.
  @sandbox_lock_namespace 4316
  @log_event_lock_namespace 4332

  # ── on the _unsafe_ prefix ────────────────────────────────────────────────
  #
  # Every function here that does not scope by `user_id` carries the prefix,
  # including the ones whose callers happen to check ownership first. That is
  # the point of a convention: the reader of a call site should not have to go
  # and find out.
  #
  # Several of these were unprefixed until #182 — `get_sandbox/1`,
  # `list_turns/1`, `list_log_events/3` and friends. No call site was wrong, but
  # nothing marked them either, so the audit that makes `_unsafe_` useful had a
  # hole exactly where it mattered least visibly.
  #
  # A legitimate caller is one of: admin surfaces behind `require_admin`,
  # system-level sweeps like the rehydrator and the reaper, or a GenServer that
  # has already established ownership. Anything user-facing wants the scoped
  # variant.

  # ── sandboxes ──────────────────────────────────────────────────────────────────────────

  @doc "List active sandboxes across all tenants (admin use only)."
  def _unsafe_list_sandboxes_admin do
    alias Fountain.Accounts.User

    Repo.all(
      from s in admin_sandboxes(),
        order_by: [desc: s.inserted_at],
        left_join: u in User,
        on: u.id == s.user_id,
        preload: [user: u, conversations: []]
    )
  end

  @doc """
  How many sandboxes `_unsafe_list_sandboxes_admin/0` would return, without
  loading them or their owners.

  Deliberately built on the same query: the admin overview shows this count
  and links to the list, and a count that came from a second definition of
  "active" would disagree with the page it points at. `Quotas` has its own,
  narrower definition (`pending`/`starting`/`ready`) because a concurrency cap
  counts sandboxes being paid for, not sandboxes on screen.
  """
  def _unsafe_count_sandboxes_admin, do: Repo.aggregate(admin_sandboxes(), :count, :id)

  defp admin_sandboxes do
    from s in Sandbox, where: s.status not in ["terminated", "failed"]
  end

  def _unsafe_get_sandbox(id), do: Repo.get(Sandbox, id)
  def _unsafe_get_sandbox!(id), do: Repo.get!(Sandbox, id)

  @doc """
  Load any tenant's conversation for the admin support view (#446).

  Returns the conversation with owner/agent/sandbox preloaded plus turn and
  log-event **counts** — deliberately not the turns or log events themselves.
  The admin surface renders metadata only (status, timing, exit codes); prompt
  and output content stay tenant-private. `_unsafe_list_turn_summaries_admin/1`
  carries the same rule.
  """
  def _unsafe_get_conversation_admin(id) do
    case Repo.get(Conversation, id) do
      nil ->
        nil

      conv ->
        conv = Repo.preload(conv, [:user, :agent, :sandbox])

        turn_count =
          Repo.aggregate(from(t in Turn, where: t.conversation_id == ^id), :count)

        log_event_count =
          Repo.aggregate(from(le in LogEvent, where: le.conversation_id == ^id), :count)

        %{conversation: conv, turn_count: turn_count, log_event_count: log_event_count}
    end
  end

  @doc """
  Turn metadata for the admin support view: numbers, statuses, exit codes and
  timing — never `prompt`. The select list is the privacy boundary; keep
  content columns out of it.
  """
  def _unsafe_list_turn_summaries_admin(conversation_id, limit \\ 100) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [desc: t.turn_number],
        limit: ^limit,
        select: %{
          id: t.id,
          turn_number: t.turn_number,
          status: t.status,
          exit_code: t.exit_code,
          started_at: t.started_at,
          ended_at: t.ended_at,
          inserted_at: t.inserted_at
        }
    )
  end

  def create_sandbox(attrs) do
    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a sandbox, emitting usage events on billable transitions.

  Almost every sandbox status change goes through here — fresh provisioning,
  the wake path, the park. Metering at this choke point means a new caller
  cannot forget to record usage, which is how `Billing.emit/5` ended up with no
  call sites at all despite being documented, schema'd and tested.

  **The one other writer is the machine's owner** (ADR 0058):
  `Fountain.Machines.Lease.cas_update/3` writes the row under the lease epoch,
  because a compare-and-set is the thing that makes a superseded owner
  invisible and this function's `FOR UPDATE` read cannot express it. It is not
  outside the metering: it calls `sandbox_status_effects/2` below, which is the
  same two effects this one runs, and `Fountain.Machines.DestroyTest` pins them
  per site. A new writer that is neither of these two is the failure mode above,
  returning.

  The persisted previous status decides the transition. Terminal rows reject
  attempts to become active again, including callbacks holding an older struct.
  """
  # The two statuses a sandbox stops at. `update_sandbox/2` reads this before
  # `prevent_sandbox_revival/1` does, so it is declared here rather than beside it.
  @billable_terminal ~w(terminated failed)

  def update_sandbox(%Sandbox{} = sandbox, attrs), do: do_update_sandbox(sandbox, attrs)

  # The two effects a sandbox status change owes, for a writer that is not
  # `update_sandbox/2`.
  #
  # `update_sandbox/2` runs `record_sandbox_usage/2` and
  # `maybe_poke_sandbox_queue/2` after its own transaction and, deliberately,
  # with the status its `FOR UPDATE` read saw rather than a fresh one (#2309).
  # `Fountain.Machines.Lease.cas_update/3` — the machine owner's write since
  # ADR 0058 — is a single guarded `update_all` and runs neither, so the owner
  # calls this after its finalize commits, outside every transaction, with the
  # row the write returned and the status it had before it.
  #
  # Both halves matter and neither is optional. `record_sandbox_usage/2` is the
  # metering choke point this context exists to keep honest — a terminal write
  # that skips it leaves `sandbox_terminated` unrecorded, and that row is what
  # a provider bill is reconciled against. `maybe_poke_sandbox_queue/2` is what
  # turns a freed quota slot into a drain (ADR 0042 decision 5): without it a
  # tenant at their cap waits for the five-minute cron instead of a second.
  #
  # A door for `Fountain.Machines` (ADR 0058); not part of the context's public
  # surface, like the two it calls.
  @doc false
  @spec sandbox_status_effects(Sandbox.t(), String.t()) :: :ok
  def sandbox_status_effects(%Sandbox{} = written, previous_status)
      when is_binary(previous_status) do
    record_sandbox_usage(previous_status, written)
    maybe_poke_sandbox_queue(previous_status, written)
    :ok
  end

  @doc """
  Update a sandbox for provisioning, wake or park, returning `:retired` when
  another operation has already retired it. Other write errors pass through.
  """
  @spec claim_sandbox(Sandbox.t(), map()) :: {:ok, Sandbox.t()} | :retired | {:error, term()}
  def claim_sandbox(%Sandbox{} = sandbox, attrs) do
    case update_sandbox(sandbox, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> if sandbox_retired?(reason), do: :retired, else: {:error, reason}
    end
  end

  @doc "Returns whether a write was rejected because the sandbox is retired."
  @spec sandbox_retired?(term()) :: boolean()
  def sandbox_retired?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:status, {"sandbox is retired", _metadata}} -> true
      _ -> false
    end)
  end

  def sandbox_retired?(_), do: false

  # Was `update_sandbox_if/3` until ADR 0058 stage 5c. The conditional half —
  # a caller-supplied predicate over the locked row — existed for one caller,
  # the reset's finalize, which used it to elect a single winner among
  # concurrent finalizers (`pending_reset_matches/2`). The machine's lease
  # elects that winner now, in front of the provider rather than behind it, so
  # the predicate went with it and every remaining caller passed `fn _ -> :ok
  # end`. The `FOR UPDATE` read below is *not* what left with it: it is what
  # `prevent_sandbox_revival/1` and the reset-fence check are decided on.
  defp do_update_sandbox(sandbox, attrs) do
    # A provider callback may still hold a starting/ready struct after reset,
    # cancellation or the provision watchdog retired the persisted row. Read
    # and validate under the row lock; checking the caller's struct would let
    # that delayed callback revive the machine. No provider I/O under this lock.
    result =
      Repo.transaction(fn ->
        current =
          Repo.one(from s in Sandbox, where: s.id == ^sandbox.id, lock: "FOR UPDATE") ||
            Repo.rollback(:not_found)

        changeset =
          current
          |> Sandbox.changeset(attrs)
          |> prevent_sandbox_revival()
          |> stamp_terminated_at()

        # A reset fence (`reset_sandbox/2`) stops this machine being re-used or
        # re-purposed while its deletion is unconfirmed. It deliberately does
        # NOT stop it being finished off, because a retiring write is how the
        # fence is *meant* to end: the reset's own confirmed destroy, an
        # operator reaping it from /admin/sandboxes, the agent being deleted,
        # account deletion, or a ConversationServer giving up on it. Every one
        # of those callers matches `{:ok, _}`, so refusing them would turn a
        # provider timeout into a MatchError and strand the row with no way to
        # retire it at all.
        if not is_nil(current.reset_requested_at) and
             Ecto.Changeset.get_field(changeset, :status) not in @billable_terminal,
           do: Repo.rollback(:sandbox_reset_pending)

        case Repo.update(changeset) do
          {:ok, updated} -> {current.status, updated}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, {was, updated}} ->
        record_sandbox_usage(was, updated)
        maybe_poke_sandbox_queue(was, updated)
        {:ok, updated}

      {:error, _} = error ->
        error
    end
  end

  # What a caller may contribute to a sandbox name — the part after this
  # tenant's prefix. See `mint_machine_name/3`. Deliberately narrow: the value
  # becomes a machine name at a provider, and the old code accepted anything.
  @machine_name_suffix ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,39}\z/

  # A transition out of a cap-counting status frees a tenant slot and the
  # deployment-wide fleet slot at once, so every tenant with live queue work
  # wants draining — not just this one (ADR 0042 decision 5). This is the
  # choke point every sandbox status change goes through and almost every one
  # of them happens with an empty queue, so the cost here is one existence
  # probe against a partial index. When there is work it is one Oban insert,
  # and the job does the scan that finds the tenants.
  defp maybe_poke_sandbox_queue(was, %Sandbox{} = updated) do
    active = Fountain.Quotas.active_statuses()

    if was in active and updated.status not in active and
         Fountain.SandboxQueue.any_active_requests?() do
      Fountain.Workers.SandboxQueueDrainer.poke_all_later()
    end

    :ok
  rescue
    # Best-effort for the same reason `Billing.record_usage/5` rescues at this
    # choke point: the row is already committed, nearly every call site matches
    # `{:ok, _}` (ConversationServer's terminate path, `Accounts.Deletion`,
    # `SandboxReaper`), and a failed poke must not take down a caller that only
    # wanted to write a status. The cron backstop drains anyway.
    e ->
      Logger.warning("sandbox queue poke failed: #{Exception.message(e)}")
      :ok
  end

  defp prevent_sandbox_revival(changeset) do
    if changeset.data.status in @billable_terminal and
         Ecto.Changeset.get_field(changeset, :status) not in @billable_terminal do
      Ecto.Changeset.add_error(changeset, :status, "sandbox is retired")
    else
      changeset
    end
  end

  # `terminated_at` is when a sandbox stopped costing money, so spend
  # attribution reads it as the end of the billed interval
  # (`Fountain.Billing.SandboxUsage`). Stamping it here rather than at each
  # call site is the same choke-point argument as the metering below: of the
  # dozen writers of a terminal status, the ones that terminate passed a
  # timestamp and the ones that fail never did, which left every failed
  # sandbox looking like it was still running years later.
  #
  # Only fills a gap — a caller that passes its own `terminated_at` keeps it.
  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def stamp_terminated_at(changeset) do
    status = Ecto.Changeset.get_field(changeset, :status)

    if status in @billable_terminal and
         is_nil(Ecto.Changeset.get_field(changeset, :terminated_at)) do
      Ecto.Changeset.put_change(
        changeset,
        :terminated_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )
    else
      changeset
    end
  end

  # Transitions only: update_sandbox/2 is called repeatedly with the same status
  # in places, and double-counting a sandbox would overstate a bill. Provision
  # transitions only — a `suspended → ready` wake reattaches to a sprite whose
  # provision was already recorded, so re-emitting would double-count it.
  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def record_sandbox_usage(was, %Sandbox{status: "ready"} = sandbox)
      when was in ["pending", "starting"] do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_provisioned",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.machine_name, "provider" => sandbox.provider}
    )
  end

  # `suspended → ready`: the wake side of a park/wake cycle (0017). No
  # sandbox_provisioned here — the provision was already recorded before the
  # sandbox parked (see above) — but the parked interval needs a start and an
  # end of its own so the duration roll-up can subtract it from
  # sandbox_terminated's duration_ms instead of billing parked time (#665).
  def record_sandbox_usage("suspended", %Sandbox{status: "ready"} = sandbox) do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_resumed",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.machine_name, "provider" => sandbox.provider}
    )
  end

  # `ready → suspended`: the sandbox is parked, not destroyed, and stops
  # billing compute from here (0017). Paired with sandbox_resumed (or, for a
  # sandbox that never wakes again, with sandbox_terminated) so the duration
  # roll-up can tell parked time apart from run time (#665).
  def record_sandbox_usage(was, %Sandbox{status: "suspended"} = sandbox)
      when was not in @billable_terminal do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_suspended",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.machine_name, "provider" => sandbox.provider}
    )
  end

  def record_sandbox_usage(was, %Sandbox{status: status} = sandbox)
      when status in @billable_terminal and was not in @billable_terminal do
    # A sandbox that dies before reaching "ready" never emitted
    # sandbox_provisioned, but it is about to emit sandbox_terminated with a
    # duration — so the conversation count and the sandbox minutes on the
    # billing page would diverge for exactly the accounts where provisioning
    # is failing. Record the attempt under its own event type so the two
    # sides can be reconciled. `suspended` had to pass through `ready` to get
    # parked, so it is a completed provision, not a failed one.
    if was in ["pending", "starting"] do
      Fountain.Billing.record_usage(
        sandbox.user_id,
        "sandbox_provision_failed",
        sandbox.id,
        "sandbox",
        %{
          "sprite_name" => sandbox.machine_name,
          "provider" => sandbox.provider,
          "status_before_failure" => was
        }
      )
    end

    # `failed` counts too: a sprite that died mid-provision still ran, and was
    # still billed by Sprites. Recording only clean terminations would
    # understate cost precisely when something is going wrong.
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_terminated",
      sandbox.id,
      "sandbox",
      %{
        "duration_ms" => sandbox_duration_ms(sandbox),
        "final_status" => status,
        "provider" => sandbox.provider
      }
    )
  end

  def record_sandbox_usage(_was, _sandbox), do: :ok

  defp sandbox_duration_ms(%Sandbox{inserted_at: nil}), do: 0

  defp sandbox_duration_ms(%Sandbox{inserted_at: started} = sandbox) do
    ended = sandbox.terminated_at || DateTime.utc_now()
    ended |> DateTime.diff(started, :millisecond) |> max(0)
  end

  # ── conversations ─────────────────────────────────────────────────────────────────────

  @doc """
  Returns all conversations in the same spawn tree as `conversation_id`,
  scoped to `user_id`.

  Each entry is a map with keys: :id, :source, :status, :parent_id

  Returns `[]` when the conversation does not exist or belongs to someone else.

  Every reference to `conversations` carries the tenant predicate. Without it
  the recursion walks straight across tenant boundaries, which leaked
  conversation ids, sources and statuses in both directions: a conversation
  parented onto another tenant's conversation pulled their whole tree into this
  view, and put this one into theirs.

  The root is the furthest *reachable* ancestor rather than the one with a NULL
  parent. For clean data those are the same node. They differ only where a
  foreign parent link already exists in the data, and picking the boundary node
  degrades to "show the part of the tree you own" instead of returning nothing.
  """
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters
  # ($1/$2 UUIDs dumped above); nothing user-controlled is interpolated.
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters
  # ($1/$2 UUIDs dumped below); nothing user-controlled is interpolated.
  def get_conversation_tree(conversation_id, user_id) when is_binary(user_id) do
    sql = """
    WITH RECURSIVE
    ancestors(id, parent_conversation_id, depth) AS (
      SELECT id, parent_conversation_id, 0
      FROM conversations WHERE id = $1 AND user_id = $2
      UNION ALL
      SELECT c.id, c.parent_conversation_id, a.depth + 1
      FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
      -- depth bound: parent links are client-supplied, and a cycle would
      -- otherwise spin this CTE forever.
      WHERE c.user_id = $2 AND a.depth < 100
    ),
    root_row AS (
      SELECT id FROM ancestors ORDER BY depth DESC LIMIT 1
    ),
    tree(id, source, status, parent_id, depth) AS (
      SELECT c.id, c.source, c.status, c.parent_conversation_id, 0
      FROM conversations c, root_row r
      WHERE c.id = r.id AND c.user_id = $2
      UNION ALL
      SELECT c.id, c.source, c.status, c.parent_conversation_id, t.depth + 1
      FROM conversations c
      INNER JOIN tree t ON c.parent_conversation_id = t.id
      WHERE c.user_id = $2 AND t.depth < 100
    )
    SELECT id, source, status, parent_id FROM tree
    """

    with {:ok, conv_uuid} <- Ecto.UUID.dump(conversation_id),
         {:ok, user_uuid} <- Ecto.UUID.dump(user_id) do
      %{rows: rows} = Repo.query!(sql, [conv_uuid, user_uuid])

      Enum.map(rows, fn [id, source, status, parent_id] ->
        %{
          id: load_uuid!(id),
          source: source,
          status: status,
          parent_id: load_uuid(parent_id)
        }
      end)
    else
      _ -> []
    end
  end

  defp load_uuid!(bin) when is_binary(bin) do
    {:ok, str} = Ecto.UUID.load(bin)
    str
  end

  defp load_uuid(nil), do: nil
  defp load_uuid(bin), do: load_uuid!(bin)

  @doc """
  Conversations whose `ConversationServer` would have been running at the
  time of a clean BEAM stop: status `idle` or `running`, with a fully-
  provisioned (`ready`) sandbox.

  `suspended` is deliberately excluded: a parked conversation has no server
  by design and wakes on the next prompt, not at boot — rehydrating every
  parked conversation would start a server (and re-arm an idle clock) for
  each one on every deploy.
  """
  def _unsafe_list_resumable_conversations do
    Repo.all(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where: c.status in ["idle", "running"] and s.status == "ready",
        preload: [:sandbox]
    )
  end

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only —
  user-facing endpoints must use the arity-2 variant that takes user_id.
  """
  def _unsafe_get_conversation(id) do
    Conversation
    |> Repo.get(id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only.
  """
  def _unsafe_get_conversation!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @doc """
  Get conversation scoped to user. A foreign, missing or malformed id reads
  as nil.

  Malformed is part of that promise rather than a caller's problem (#1679):
  the id reaches here from a path segment or a header, and an id that is not
  a uuid raises `Ecto.Query.CastError` out of the query, which leaves the
  request as a 500 with a dropped connection instead of the 404 every caller
  of this function already handles. `dump/1` rather than `cast/1` because
  `cast/1` takes any 16-byte binary, so a sixteen-character name would pass
  the guard and raise at the same place.
  """
  def get_conversation(id, user_id) when is_binary(user_id) do
    with {:ok, _} <- Ecto.UUID.dump(id),
         conv when not is_nil(conv) <- Repo.get_by(Conversation, id: id, user_id: user_id) do
      Repo.preload(conv, [:sandbox, :agent, :vault, :agent_version])
    else
      _ -> nil
    end
  end

  @doc "Get conversation scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_conversation!(id, user_id) when is_binary(user_id) do
    Conversation
    |> Repo.get_by!(id: id, user_id: user_id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @typedoc """
  A period's tokens, as the runtimes reported them. `cache_read` and
  `cache_write` are prompt-cache traffic; see `total_input/1`.
  """
  @type token_usage :: %{
          input: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          output: non_neg_integer()
        }

  @token_keys [:input, :cache_read, :cache_write, :output]

  # Only a JSON number is cast. `usage` is whatever the runtime reported and
  # nothing validates its shape on the way in, so one row with a string where
  # a number belongs would otherwise take the whole page down with it.
  defmacrop token_sum(usage, key) do
    quote do
      fragment(
        "CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::bigint ELSE 0 END",
        unquote(usage),
        unquote(key),
        unquote(usage),
        unquote(key)
      )
    end
  end

  @doc """
  What this tenant's agents spent, in tokens, over a period.

  Summed from `turns.usage` — the figure the runtime reported when the turn
  ended. Reading the turns rather than `conversations.usage_input_tokens` is
  what makes a period possible: those counters are lifetime totals, and a
  conversation started in March is still accruing in April.

  **All four keys, not two.** A coding agent re-reads its context every turn,
  so nearly everything it consumes arrives as `cache_read`: a month of real
  work on this instance was 1.5k `input` against 41M `cache_read`. Reporting
  `input` alone as "what went in" understates it by four orders of magnitude,
  which is worse than not reporting it at all. Callers get the breakdown and
  decide how to present it; `total_input/1` is the sum for the common case.

  Tokens are the tenant's own inference spend — Fountain runs on their key
  (ADR 0008) and never bills for them — so this is reported, not charged.
  Turns from before the usage column existed, and runtimes that report no
  usage, contribute nothing rather than a guess.
  """
  @spec token_usage(binary(), DateTime.t(), DateTime.t()) :: token_usage()
  def token_usage(user_id, %DateTime{} = from, %DateTime{} = to) when is_binary(user_id) do
    # The sum happens in Postgres: a busy month is tens of thousands of turns,
    # and this runs on a page load.
    #
    # `jsonb_typeof` before the cast, because `usage` is whatever the runtime
    # reported and nothing validates its shape on the way in. One row with a
    # string or an object where a number was expected would otherwise take
    # the whole page down with a cast error.
    query =
      from(t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.user_id == ^user_id and t.inserted_at >= ^from and t.inserted_at <= ^to,
        where: not is_nil(t.usage),
        select: %{
          input: sum(token_sum(t.usage, "input")),
          cache_read: sum(token_sum(t.usage, "cache_read")),
          cache_write: sum(token_sum(t.usage, "cache_write")),
          output: sum(token_sum(t.usage, "output"))
        }
      )

    case Repo.one(query) do
      %{} = row -> Map.new(@token_keys, &{&1, to_count(Map.get(row, &1))})
      _ -> empty_token_usage()
    end
  end

  @doc """
  Everything the model read: fresh input plus what it wrote to and read from
  the prompt cache. The cached reads dominate, and leaving them out is what
  made the first version of this metric wrong.
  """
  @spec total_input(token_usage()) :: non_neg_integer()
  def total_input(%{input: input, cache_read: read, cache_write: write}),
    do: input + read + write

  defp empty_token_usage, do: Map.new(@token_keys, &{&1, 0})

  # Postgres sums bigints as `numeric`, which arrives as a Decimal. The
  # callers of this want an integer they can format, and the spec says so.
  defp to_count(nil), do: 0
  defp to_count(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_count(n) when is_integer(n), do: n

  @doc """
  How many conversations this tenant has, and how many are live right now.

  Counted in the database. The console's dashboard wants two numbers, not the
  rows: loading a few hundred conversations with their agents and first turns
  to arrive at "3" is a page load nobody needs.
  """
  @spec conversation_counts(binary()) :: %{total: non_neg_integer(), active: non_neg_integer()}
  def conversation_counts(user_id) when is_binary(user_id) do
    query =
      from(c in Conversation,
        where: c.user_id == ^user_id,
        select: %{
          total: count(c.id),
          active: filter(count(c.id), c.status in ["pending", "running"])
        }
      )

    Repo.one(query) || %{total: 0, active: 0}
  end

  @doc """
  List conversations for user, ordered by most recently updated.

  Pass `roots_only: true` to exclude child conversations (those with a
  `parent_conversation_id`). Useful for hiding agent-spawned sub-conversations
  from the index when the user only wants to see top-level sessions.

  Further filters (#832), all combinable: `agent_id: id`, `channel_id:
  "fountain:team"` (the *bound* channel — a conversation unbound by
  `Fountain.Team.remove_teammate/3` no longer matches; a teammate's full
  history is `Team.list_teammate_conversations/2`), and `status: [..]` (a
  list of conversation statuses), and `sandbox_id: id`. Unpaged, like the list always was, except
  for `limit: n` — which the console's dashboard uses to ask for the five it
  shows instead of every row a busy account has.

  `labels: %{"env" => "prod"}` (#1637) keeps the conversations carrying every
  one of those pairs — jsonb containment, so a row with more labels than the
  filter names still matches, and the GIN index on the column serves it.

  Populates the `last_active_at` virtual field using `kind: "output"` log
  events only — stage events (reconnects, lifecycle) are excluded so
  reconnects don't produce false unread indicators.
  """
  def list_conversations(user_id, opts \\ []) when is_binary(user_id) do
    roots_only = Keyword.get(opts, :roots_only, false)

    base = from(c in annotated_query(user_id), order_by: [desc: c.updated_at, desc: c.id])

    base =
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> limit(base, ^n)
        _ -> base
      end

    query =
      if roots_only do
        where(base, [conv: c], is_nil(c.parent_conversation_id))
      else
        base
      end

    query =
      Enum.reduce(opts, query, fn
        {:agent_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.agent_id == ^id)

        {:sandbox_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.sandbox_id == ^id)

        {:channel_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.channel_id == ^id)

        {:labels, labels}, q when is_map(labels) and map_size(labels) > 0 ->
          where(q, [conv: c], fragment("? @> ?", c.labels, type(^labels, :map)))

        {:status, [_ | _] = statuses}, q ->
          where(q, [conv: c], c.status in ^statuses)

        _, q ->
          q
      end)

    Repo.all(query)
    |> Repo.preload([:agent, :agent_version, turns: first_turn_query()])
  end

  @doc """
  Every conversation of `user_id` bound to `channel_id`, live or not, newest
  activity first, with the read-model annotations (`turn_count`,
  `last_active_at`) populated and `:agent` + `:sandbox` preloaded.

  The channel-bound counterpart of `list_conversations/2`. Terminated and
  failed conversations are included on purpose: a binding outlives its
  sandbox (`start_or_resume_conversation/2` opens a new one next time), and
  the surface reading a channel — the team page — wants the last transcript
  even when nothing is running.
  """
  def list_channel_conversations(user_id, channel_id, opts \\ [])
      when is_binary(user_id) and is_binary(channel_id) do
    from(c in annotated_query(user_id),
      where: c.channel_id == ^channel_id,
      order_by: [desc: c.inserted_at, desc: c.id]
    )
    |> filter_by_labels(Keyword.get(opts, :labels))
    |> Repo.all()
    |> Repo.preload([:agent, :sandbox])
  end

  # The same containment filter `list_conversations/2` applies (#1637), for
  # the channel-bound list behind the team route.
  defp filter_by_labels(query, labels) when is_map(labels) and map_size(labels) > 0 do
    where(query, [conv: c], fragment("? @> ?", c.labels, type(^labels, :map)))
  end

  defp filter_by_labels(query, _labels), do: query

  @doc """
  Scoped fetch that also populates the read-model annotations —
  `turn_count` and `last_active_at` — which `get_conversation/2` leaves at
  their defaults.

  Separate from `get_conversation/2` on purpose: that one is on the hot path
  of every prompt and interrupt, and does not need two extra joins to answer
  "does this conversation exist and is it yours".
  """
  def get_conversation_with_activity(id, user_id) when is_binary(user_id) do
    case Repo.one(from(c in annotated_query(user_id), where: c.id == ^id)) do
      nil ->
        nil

      # The first turn rides along, as it does on the list: `first_prompt` in
      # the JSON is what a client titles an untitled conversation with.
      conv ->
        Repo.preload(conv, [:sandbox, :agent, :vault, :agent_version, turns: first_turn_query()])
    end
  end

  # The conversation list read-model: turn counts and last activity, both as
  # LEFT JOIN LATERAL subqueries so the result stays a plain list of structs
  # and no caller N+1s.
  #
  # Lateral, per conversation, rather than one GROUP BY over the whole table
  # joined back (2026-09-07). The grouped shape aggregated every output log
  # event in the deployment on every call — a full scan of log_events, the
  # largest table, for a list of one tenant's conversations — and a client
  # polling this list 14 times a second turned that into 6.4M sequential
  # scans and a pool exhausted for everyone. Per conversation, the newest
  # output event is one backward probe of the partial index
  # `log_events_output_conversation_id_inserted_at_index`, and the cost
  # scales with the tenant's conversation count instead of the table.
  #
  # Only `kind: "output"` log events count toward `last_active_at` — stage
  # events (reconnects, sandbox lifecycle) would otherwise produce false
  # unread indicators.
  defp annotated_query(user_id) do
    from c in Conversation,
      as: :conv,
      where: c.user_id == ^user_id,
      left_lateral_join: tc in subquery(turn_count_of_conv()),
      on: true,
      left_lateral_join: ll in subquery(last_output_at_of_conv()),
      on: true,
      select: %{
        c
        | turn_count: fragment("COALESCE(?, 0)", tc.count),
          last_active_at:
            fragment(
              "COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC')",
              ll.last_at,
              c.inserted_at
            )
      }
  end

  # The lateral halves of the read-model. Each answers for the conversation
  # bound as `:conv` in the outer query, so they compose only under a `from`
  # that names that binding.
  defp turn_count_of_conv do
    from t in Turn,
      where: t.conversation_id == parent_as(:conv).id,
      select: %{count: count(t.id)}
  end

  defp last_output_at_of_conv do
    from le in LogEvent,
      where: le.conversation_id == parent_as(:conv).id and le.kind == "output",
      select: %{last_at: max(le.inserted_at)}
  end

  @doc """
  Whether a conversation has activity the owner has not seen.

  Unread until read at least once; read conversations go unread again when
  output arrives after the last read. Lived in three copies across the nav,
  the index and (implicitly) the API — one definition, so they cannot drift.
  """
  def unread?(%{last_read_at: nil, last_active_at: _}), do: true
  def unread?(%{last_read_at: _, last_active_at: nil}), do: false

  def unread?(%{last_read_at: read_at, last_active_at: active_at}),
    do: DateTime.compare(active_at, read_at) == :gt

  def unread?(_), do: false

  def create_conversation(attrs) do
    with {:ok, conv} <- insert_conversation_row(attrs) do
      after_conversation_created(conv)
      {:ok, conv}
    end
  end

  # The one place a conversation row is written. Admission writes it inside a
  # transaction with the sandbox and the execution allowance, so it cannot
  # share `create_conversation/1` outright; keeping the insert itself in one
  # function is what stops the two shapes drifting.
  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def insert_conversation_row(attrs) do
    %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()
  end

  # The account's first conversation is the request the verified landing handed
  # over (ADR 0038), and this is the funnel's third step. It is deliberately
  # *not* inside `insert_conversation_row/1`: a caller in a transaction must
  # fire it after that transaction commits, so a rolled-back write reports no
  # request. Every door that inserts a conversation calls it exactly once —
  # `create_conversation/1`, `create_attached_conversation/3`,
  # `reserve_initial_conversation/3` — and
  # `conversation_creation_seam_test.exs` drives each of them and fails if one
  # stops firing.
  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def after_conversation_created(%Conversation{} = conv) do
    Fountain.Activation.conversation_created(conv)
  end

  @doc """
  Merge `labels` into `conversation_id`'s. **The door every request-shaped
  caller uses** (#1637).

  Merge, not replace: a key that is not named is left alone and a key whose
  value is `nil` is removed, so a run can stamp one outcome without reading
  the rest first. `Conversations.Labels` owns the limits, and a write that
  breaks one comes back as a changeset naming the offending key.

  **A sandbox may label its own conversation only.** Pass
  `sandbox_key_id: key.id` whenever the caller authenticated with a
  `sprite`-scoped token: the conversation must be the one that token was
  minted for (`callback_api_key_id`), or the write is refused with
  `:sprite_may_not_label_another_conversation`. Without that check a worker
  holding an account-scoped callback key could relabel every other run on the
  account, which is exactly the loop ADR 0045 describes. That is why the
  check lives here and not in each controller: `PATCH .../labels`, the team
  message and a `channel_id` resume all write labels, and the rule has to
  hold on the door rather than on whichever of them remembered.

  `labels` that is not a map at all is a validation failure, not a silent
  no-op, so every door refuses `{"labels": "env=prod"}` the same way.

  Tenant-scoped: an id belonging to another account reads as `:not_found`.
  """
  @spec set_conversation_labels(binary(), binary(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def set_conversation_labels(conversation_id, user_id, labels, opts \\ [])
      when is_binary(conversation_id) and is_binary(user_id) do
    case get_conversation(conversation_id, user_id) do
      nil ->
        {:error, :not_found}

      %Conversation{} = conv ->
        if sandbox_owns?(conv, Keyword.get(opts, :sandbox_key_id)) do
          # Ownership: `conv` came from the tenant-scoped fetch above.
          _unsafe_merge_labels(conv, labels, opts)
        else
          {:error, :sprite_may_not_label_another_conversation}
        end
    end
  end

  # No sandbox key on the request is the owner's own credential, which may
  # label any conversation it can already fetch.
  defp sandbox_owns?(_conv, nil), do: true
  defp sandbox_owns?(%Conversation{callback_api_key_id: id}, key_id), do: id == key_id

  @doc """
  Merge `labels` into a conversation row, with no tenant scoping and no
  credential rule.

  Unscoped, hence the prefix. The legitimate callers are
  `set_conversation_labels/4`, which scopes and applies the sandbox rule
  before delegating here, and `Labels._unsafe_stamp/2`, which runs inside the
  conversation's own server and holds the row that server was started for. A
  request path that calls this directly has skipped the rule that stops one
  sandbox relabelling another, so do not add one.

  A merge that changes nothing writes nothing and records nothing — a
  deterministic run re-stamping the same outcome on every tick is the normal
  case. Audited as `conversation.labels_set` with the keys written and the
  keys removed, never the values (ADR 0013).
  """
  @spec _unsafe_merge_labels(Conversation.t(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def _unsafe_merge_labels(conv, labels, opts \\ []) do
    with {:ok, updated, audit} <- merge_labels(conv, labels) do
      audit_labels(updated, audit, opts)
      {:ok, updated}
    end
  end

  defp merge_labels(%Conversation{} = conv, labels) when is_map(labels) do
    current = conv.labels || %{}
    merged = Labels.merge(current, labels)

    cond do
      merged == current -> {:ok, conv, nil}
      true -> write_labels(conv, current, labels, merged)
    end
  end

  # Anything that is not a map is a validation failure with the same shape a
  # broken limit produces, so a caller reads one answer whichever door it
  # came through.
  defp merge_labels(%Conversation{} = conv, labels) do
    {:error, label_refusal(conv, Labels.check(labels))}
  end

  defp write_labels(conv, current, labels, merged) do
    case Labels.check_merge(current, labels) do
      :ok ->
        {written, removed} = Labels.changed_keys(current, labels)

        conv
        |> Conversation.changeset(%{labels: merged})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated, {written, removed, merged}}
          error -> error
        end

      refusal ->
        {:error, label_refusal(conv, refusal)}
    end
  end

  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def audit_labels(_conv, nil, _opts), do: :ok

  def audit_labels(conv, {written, removed, merged}, opts),
    do: record_labels_set(conv, written, removed, merged, opts)

  defp record_labels_set(conv, written, removed, merged, opts) do
    Audit.record(%{
      user_id: conv.user_id,
      action: "conversation.labels_set",
      resource_type: "conversation",
      resource_id: conv.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "keys" => written,
        "removed_keys" => removed,
        "label_count" => map_size(merged)
      }
    })
  end

  # `Labels.check_merge/2` words the refusal from the write the caller made;
  # this is what turns that sentence into the `errors.labels` a 422 renders,
  # the same key the changeset validator would have used.
  defp label_refusal(%Conversation{} = conv, {:error, message}) do
    conv
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:labels, message)
  end

  def update_conversation(%Conversation{} = conv, attrs) do
    conv
    |> Conversation.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_sidebar_update(updated.user_id)
      _ -> :ok
    end)
  end

  @doc "Apply a harness title without overwriting an explicit name or a teammate's name."
  def _unsafe_update_harness_title(conversation_id, title)
      when is_binary(title) or is_nil(title) do
    team_channel = Fountain.Team.channel()

    # A single conditional write arbitrates against concurrent user renames.
    # Updating title_source also lets an owner claim an unchanged harness title.
    query =
      from(c in Conversation,
        where: c.id == ^conversation_id,
        where: is_nil(c.channel_id) or c.channel_id != ^team_channel,
        where: is_nil(c.title) or c.title_source == "harness",
        where: fragment("? IS DISTINCT FROM ?", c.title, ^title),
        select: c.user_id
      )

    case Repo.update_all(query,
           set: [title: title, title_source: "harness", updated_at: DateTime.utc_now(:second)]
         ) do
      {1, [user_id]} -> broadcast_sidebar_update(user_id)
      {0, _} -> :ok
    end
  end

  @doc "Idle only the latest ended turn's still-running parent."
  def _unsafe_idle_after_turn(%Turn{} = turn),
    do: write_turn_parent(turn, :idle, %{status: "idle"})

  @doc "Apply a runtime session report only for the current, unretired turn."
  def _unsafe_set_turn_session(%Turn{} = turn, session_id),
    do: write_turn_parent(turn, :session, %{runtime_session_id: session_id})

  @doc "Clear an idle legacy peer's session only if its observed identity is still current."
  def _unsafe_clear_idle_session(conv_id, expected) do
    # ownership: this is the already-owned actor's conversation and session.
    ExecutionGuard._unsafe_clear_idle_session(conv_id, expected, fn current ->
      current |> Conversation.changeset(%{runtime_session_id: nil}) |> Repo.update()
    end)
    |> notify_parent_change()
  end

  defp write_turn_parent(turn, mode, attrs) do
    # ownership: the calling actor/recovery path already owns this exact turn.
    result =
      ExecutionGuard._unsafe_write_parent(turn, mode, fn current ->
        current |> Conversation.changeset(attrs) |> Repo.update()
      end)

    notify_parent_change(result)
  end

  defp notify_parent_change(result) do
    case result do
      {:ok, %{applied: true, conversation: conv}} -> broadcast_sidebar_update(conv.user_id)
      _ -> :ok
    end

    result
  end

  # How long a caller waits for advisory lock 4316 before giving up
  # (ADR 0058 stage 6b, carried from 6a's locks review §6).
  #
  # Every transaction this function opens is short and database-only: the
  # longest is `Machines.Lease.claim/4`'s indexed `FOR UPDATE` read and one
  # `update_all`, and `register_server/2`'s marker is the same shape. Nothing
  # holds this lock across provider I/O — the two protocols take the lock to
  # *claim*, then do their checkpoint, suspend or destroy outside it — so five
  # seconds is not a bound anyone should ever reach.
  #
  # It is here because stage 6b makes the lock contended for the first time. A
  # park now takes it on every idle sweep, and a wake takes it through
  # `register_server/2` before it starts a server; with no timeout, a wake
  # blocked behind a claim whose transaction had somehow stalled would wait
  # for as long as that lasted, with nothing to log and nothing to refuse.
  #
  # `55P03` (`lock_not_available`) is raised out of `Repo.query!` below and
  # caught by this function's own `rescue`, which answers
  # `{:error, :sandbox_unavailable}`. It does **not** travel as
  # `Lease.guarded/2`'s `{:database, _}` shape: `guarded/2` wraps the call to
  # this function, and this function no longer lets the exception out.
  #
  # `SET LOCAL`, so it lasts exactly this transaction and no other work on the
  # pooled connection inherits it — and it applies to **every** lock this
  # transaction takes, not only the advisory one: the `FOR UPDATE` reads its
  # callers make are under it too. That is the intent rather than a side
  # effect; a row lock held for five seconds by something else is the same
  # problem from the other end. It does not cover the sites that take 4316
  # with their own `Repo.query!` — the teardown fence, the reset front door,
  # turn admission — and that is deliberate for now: those hold the lock for
  # the same kind of short database work, and giving a fence a new way to fail
  # is a decision for the stage that moves it behind the owner.
  #
  # Overridable so `machines/park_test.exs` can drive the timeout against a
  # genuinely held lock without spending five seconds on it. Nothing in `lib/`
  # sets it.
  @sandbox_lock_timeout_ms 5_000

  defp sandbox_lock_timeout_ms,
    do: Application.get_env(:fountain, :sandbox_lock_timeout_ms, @sandbox_lock_timeout_ms)

  # The lock turn admission takes, so a reapply and a turn start cannot
  # interleave on one machine. `nil` is a conversation whose machine has not
  # been minted yet; there is nothing to serialize against.
  # A door for `Fountain.Conversations.Reapply` (#2215) and
  # `Fountain.Conversations.Launch` (#2216); not part of the context's public
  # surface.
  @doc false
  def with_sandbox_lock(sandbox_id, fun) do
    Repo.transaction(fn ->
      if sandbox_id do
        Repo.query!("SET LOCAL lock_timeout = '#{sandbox_lock_timeout_ms()}ms'")

        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox_id)
        ])
      end

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    # The timeout above arrives as an exception out of `Repo.query!`, and every
    # caller here already has a `{:error, reason}` path, so it becomes one
    # rather than unwinding through a launch or a wake.
    #
    # For a caller that was not already in a transaction, this one has been
    # rolled back by the time the rescue runs and the advisory lock went with
    # it. Two callers *are* — `Reapply.reapply_conversation/3` and
    # `Launch.resume_channel/4`, both inside
    # `InferenceCredentials.with_source_lock/2` — and there the enclosing
    # transaction is aborted by the failed statement: Ecto opens no savepoint
    # for a nested `Repo.transaction`, so there is nothing to roll back to and
    # any further query on that connection would fail too. The refusal this
    # returns is therefore one those two may carry *outward* and never act on
    # and continue from — and neither does: both hand it to their own
    # `{:error, _}` path and unwind. Worth saying, because the word looks
    # recoverable and inside those two the transaction around it is not.
    #
    # The word is `:sandbox_unavailable` and not a new one: "this machine
    # cannot be reached right now" is exactly what it means, it is already 503
    # with a `Retry-After` and `NotReadyError` in all four SDKs, and stage 6's
    # decision was to reuse it rather than teach five clients a second word
    # (#2304, closed unmerged). Out of `Machines.Lease.claim/4` it can mean
    # nothing else — that function's own refusals are `{:held, _, _}`,
    # `:not_found` and `:lost` — which is what lets the two protocols' busy
    # waits treat it as contention and keep waiting.
    error in Postgrex.Error ->
      if lock_timeout?(error) do
        # Deliberately not "advisory lock 4316 was held": the timeout covers
        # every lock this transaction waits on, so a `FOR UPDATE` row lock held
        # by somebody else lands here too, and naming the wrong one sends an
        # operator looking in the wrong place.
        Logger.warning(
          "a lock on sandbox #{inspect(sandbox_id)} was not available within the " <>
            "#{sandbox_lock_timeout_ms()}ms lock_timeout; refusing"
        )

        {:error, :sandbox_unavailable}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp lock_timeout?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_timeout?(_error), do: false

  @doc """
  Start a `ConversationServer` and publish that fact where every node can see
  it (ADR 0058 stage 6a, #2307 constraint 4).

  **The only door onto `Fountain.ConversationSupervisor`.** All three starters
  — `Launch.start_conversation/2`'s fresh path, `Wake.start_conversation_server/4`
  and `Rehydrator.spawn_server/1` — come through here, and
  `machines/register_server_test.exs` pins that nothing else names the
  supervisor.

  Horde's registry is an asynchronous CRDT. A reaper pass on another node can
  read `ConversationServer.whereis/1` as `nil` for a beat after a server
  registers here, and no amount of re-reading that registry closes a real
  distributed-ordering gap: "not here" is not "nowhere". So the registration
  gets a durable half. In order:

    1. Under `with_sandbox_lock/2`, in one short transaction: re-read the row
       `FOR UPDATE`, refuse with `{:error, :sandbox_unavailable}` if an owner
       holds a live lease on it (`Machines.Machine.busy?/2`), and otherwise
       stamp `woken_at = now`. Committed *before* anything is asked of Horde.
    2. `Horde.DynamicSupervisor.start_child/2`, outside that lock and outside
       any transaction.

  **Why the check is here as well as in the readers** (round 1, locks review).
  `Wake.maybe_reuse_sandbox/1` reads the row with no lock at all, so a
  `Lease.claim/4` landing between that read and this call would otherwise get a
  `ConversationServer` started on a machine somebody is destroying — the
  check-then-act window #2307 constraint 1 names. This door already takes the
  very advisory lock `Lease.claim/4` takes, so asking again inside it closes
  that window for nothing. The attach door never had it: its second verdict is
  made under a `FOR NO KEY UPDATE` re-read, which conflicts with the claim's
  `FOR UPDATE` and so genuinely serialises rather than merely arriving later.

  The marker itself is an `update_all` on the primary key rather than a
  changeset: control-plane bookkeeping about a process, not a state change on
  the machine, so it deliberately does not run `update_sandbox/2`'s guards,
  metering or queue poke, and it is not routed through
  `Machines.Lease.cas_update/3` either — a starter holds no lease and must not
  appear to.

  **It clears a stale `transition` in the same write** (stage 6b). Reaching
  that line means the check above found no live lease, which by 6a's own
  definition makes any stamp on the row an operation whose owner died — and
  nothing else was clearing it. `Machine.busy?/2` ignores it deliberately, the
  wake path reuses the row without touching it, and the reaper's sweeps only
  ever see machines with no server, so a stamp left on a machine that is then
  woken survived for ever. The next owner to claim that machine read the stamp
  as *its own* interrupted operation and picked the work up from the middle, on
  a machine that had since been in use.

  What clearing it costs the two protocols is a shortcut, not correctness, and
  that is worth being exact about, because this deletes what one of them reads.
  `Machines.Park`'s takeover revalidates everything under its own lease before
  it touches the machine, so a cleared stamp sends the next park down the
  ordinary path — which is where a machine that has been in use since belongs.
  `Machines.Destroy` continues from a `destroying` stamp to skip its fence and
  its own stamp; without one it re-enters at the fence, and
  `Lifecycle.fence_sandbox_for_teardown/2` keeps an existing
  `teardown_requested_at` rather than writing a second, so the repeat is
  idempotent — and a row that has already gone terminal answers
  `{:ok, :already_terminal}`. Neither loses anything it needs.

  Safe here because the advisory lock this holds is the one a claim takes: a
  claimant arriving after this takes a new epoch and stamps afresh.

  **Refuses an enclosing transaction**, the same guard `Machines.Destroy.run/2`
  carries and for the same reason (#2307 constraint 3): `with_sandbox_lock/2`
  is a plain `Repo.transaction`, so nested it would join the caller's via a
  savepoint and hold `pg_advisory_xact_lock(4316, …)` until the *outer* commit
  — across `start_child`, breaking both promises above with nothing failing.
  No caller does this today; the guard is here because "For 6b" names this
  function as the seam a park will hold a wake against, which is when one
  becomes likely.

  **Horde's answer is passed back verbatim, including
  `{:error, {:already_started, pid}}`**, because the two callers do not mean
  the same thing by it and normalizing it here would break one of them.
  `Rehydrator.spawn_server/1` reads it as success: its sweep started a server
  another node had already started, and the server is running, which is what it
  asked for. `Wake.start_conversation_server/4` reads it as *losing a race it
  has to compensate for*: on the fresh-sandbox path the loser has just created
  a sandbox row of its own, and the winner is serving the conversation on a
  different machine, so the loser retires its row and hands the prompt over
  (#717, #330). Swallowing the tuple here would repoint the conversation at the
  loser's machine — the exact bug #717 closed.

  What this door does own is that the marker is committed first, and that the
  two starters cannot drift on it.

  The two are not atomic, and that is why the marker is a *grace* condition
  rather than a veto: a caller that dies between them leaves a marker with no
  child, and `SandboxReaper`'s two liveness passes ignore a marker older than
  `@abandoned_grace_minutes`. Being late to reap a genuinely abandoned row
  costs fifteen minutes; killing a live server costs the queued prompt on it.

  `sandbox_id` may be `nil` (nothing to mark, as `with_sandbox_lock/2` already
  allows), and a row that is gone by the time the lock is taken is logged and
  stepped over — a vanished sandbox is the child's problem to discover, not a
  reason to refuse to start it here. A *busy* machine is the one case that does
  refuse, and it refuses with the word its readers use.
  """
  # The child spec is whatever `Horde.DynamicSupervisor.start_child/2` takes,
  # which is `DynamicSupervisor`'s own contract: every caller here passes
  # `Launch.child_spec/3`'s `{ConversationServer, args}` tuple rather than a map.
  @spec register_server(
          String.t() | nil,
          Supervisor.child_spec() | {module(), term()} | module()
        ) :: {:ok, pid()} | {:error, term()}
  def register_server(sandbox_id, child_spec) do
    with :ok <- mark_woken(sandbox_id) do
      Horde.DynamicSupervisor.start_child(Fountain.ConversationSupervisor, child_spec)
    end
  end

  defp mark_woken(nil), do: :ok

  defp mark_woken(sandbox_id) do
    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      sandbox_id |> claim_registration() |> report_registration(sandbox_id)
    end
  end

  defp claim_registration(sandbox_id) do
    with_sandbox_lock(sandbox_id, fn ->
      # The verdict is made on the locked read, never on the struct a caller
      # brought: a pre-lock reading is stale by construction, which is what
      # makes this worth doing twice.
      current =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^sandbox_id,
            select: %{lease_node: s.lease_node, lease_until: s.lease_until},
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          {:ok, :no_row}

        Machine.busy?(current) ->
          {:error, :sandbox_unavailable}

        true ->
          {count, _} =
            Repo.update_all(
              from(s in Sandbox, where: s.id == ^sandbox_id),
              set: [woken_at: DateTime.utc_now(), transition: nil, transition_reason: nil]
            )

          {:ok, count}
      end
    end)
  end

  # A row that vanished between the caller's read and this lock is not a reason
  # to refuse to start the server: a server on a machine whose row is gone
  # discovers that for itself, and refusing here would turn a rare race into a
  # failed wake.
  defp report_registration({:ok, :no_row}, sandbox_id) do
    Logger.warning(
      "register_server: no sandbox #{sandbox_id} to mark woken; starting the server anyway"
    )

    :ok
  end

  defp report_registration({:ok, 1}, _sandbox_id), do: :ok

  defp report_registration({:ok, 0}, sandbox_id) do
    Logger.warning(
      "register_server: sandbox #{sandbox_id} vanished under the lock; starting the server anyway"
    )

    :ok
  end

  defp report_registration({:error, _reason} = error, _sandbox_id), do: error

  @doc """
  Best-effort terminate the running ConversationServer (destroys the sprite
  if alive), then delete the conversation row. Cascades to turns and log
  events via the FK.
  """
  def delete_conversation(%Conversation{} = conv, opts \\ []) do
    # ownership: conv is the caller's tenant-scoped row. Persist cleanup before
    # any potentially blocking termination and before deleting that parent.
    with {:ok, _} <- Interruption.retire_journal_before_reattach(conv.id) do
      delete_after_journal_interrupt(conv, opts)
    end
  end

  defp delete_after_journal_interrupt(%Conversation{id: id, user_id: user_id} = conv, opts) do
    # `audit: false` on the cascade: this terminate is an implementation
    # detail of deleting, not a second thing the user asked for, and the
    # `conversation.deleted` below already accounts for the sandbox going
    # away. Without it every delete would read as terminate-then-delete.
    _ = Termination.terminate_conversation(id, audit: false)
    result = Repo.delete(conv)

    if match?({:ok, _}, result) do
      broadcast_sidebar_update(user_id)

      Audit.record(%{
        user_id: user_id,
        action: "conversation.deleted",
        resource_type: "conversation",
        resource_id: id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{"title" => conv.title}
      })
    end

    result
  end

  @doc """
  Record that `user_id` has read `conversation_id` as of now.

  Scoped to owner — silently no-ops for a wrong user_id. Broadcasts a
  sidebar update so the unread dot clears in the nav without waiting for
  the next natural PubSub event.
  """
  def mark_read(conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update_all(
           from(c in Conversation,
             where: c.id == ^conversation_id and c.user_id == ^user_id
           ),
           set: [last_read_at: now]
         ) do
      {0, _} ->
        :ok

      {_, _} ->
        broadcast_sidebar_update(user_id)
        :ok
    end
  end

  # ── turns ─────────────────────────────────────────────────────────────────────────────

  def _unsafe_list_turns(conversation_id) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.turn_number],
        preload: [images: ^from(i in TurnImage, order_by: [asc: i.position])]
    )
  end

  @doc """
  Fetch a turn by conversation, scoped to the owning user.

  Joins through the conversation so a turn belonging to another tenant is
  indistinguishable from one that doesn't exist.
  """
  def get_turn_by_conversation(turn_id, conversation_id, user_id) when is_binary(user_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where:
          t.id == ^turn_id and t.conversation_id == ^conversation_id and
            c.user_id == ^user_id,
        select: t
    )
  end

  def _unsafe_insert_turn_images(_turn_id, []), do: {:ok, 0}

  @doc """
  Store a turn's images.

  Goes through `TurnImage.changeset/2` rather than `Repo.insert_all` against a
  raw table name. The old path skipped the schema entirely, so the media-type
  allowlist, the required fields and the `(turn_id, position)` unique constraint
  never ran — the schema described validation that nothing performed, and a
  client could store an arbitrary media type. Volume here is a handful of rows
  per turn, so there was never a bulk-insert win to protect.

  Returns `{:ok, count}` or `{:error, changeset}`. Both are handled by the
  caller; a rejected image must not take a turn down with it.
  """
  def _unsafe_insert_turn_images(turn_id, images) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    images
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {%{media_type: mt, data: data}, idx}, {:ok, count} ->
      changeset =
        TurnImage.changeset(%TurnImage{}, %{
          turn_id: turn_id,
          position: idx,
          media_type: mt,
          data: data,
          inserted_at: now
        })

      case Repo.insert(changeset) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end

  def _unsafe_get_turn_image(turn_id, position) do
    Repo.get_by(TurnImage, turn_id: turn_id, position: position)
  end

  def _unsafe_next_turn_number(conversation_id) do
    last =
      Repo.one(
        from t in Turn,
          where: t.conversation_id == ^conversation_id,
          select: max(t.turn_number)
      )

    (last || 0) + 1
  end

  def _unsafe_create_turn(attrs) do
    with {:ok, turn} <- %Turn{} |> Turn.changeset(attrs) |> Repo.insert() do
      record_turn_usage(turn)
      {:ok, turn}
    end
  end

  @doc """
  Create a turn on a sandbox that may be shared, refusing when the runtime's
  capacity is used up by another conversation's running turn.

  `revision` is the conversation's `configuration_revision` as the caller
  understands it, or nil for a caller with none; a mismatch answers
  `{:error, :configuration_changed}` (#1565).

  `capacity` is `Managoat.Runtimes.ACP.concurrency/1`. All runtimes take the
  per-sandbox advisory lock and verify that the conversation still belongs
  to this nonterminal sandbox. The conversation row stays locked through the
  insert: an earlier reassignment refuses this sandbox, while a later forced
  reassignment can move a conversation whose turn was already admitted. This
  ordering does not make arbitrary reassignment writers check for running turns.
  An integer capacity also limits concurrent turns; `:unbounded` skips only that
  capacity check. Saved execution allowances
  are checked under row locks; no runtime control is supported yet, so any
  nonempty allowance refuses the turn. Refusal writes no turn.
  Usage is recorded after the transaction commits, never inside it.
  """
  def _unsafe_create_turn_on_sandbox(attrs, sandbox_id, capacity, revision \\ nil)
      when is_binary(sandbox_id) and
             (capacity == :unbounded or (is_integer(capacity) and capacity > 0)) do
    conv_id = Map.fetch!(attrs, :conversation_id)

    result =
      Repo.transaction(fn ->
        user_id =
          Repo.one(from c in Conversation, where: c.id == ^conv_id, select: c.user_id) ||
            Repo.rollback(:sandbox_unavailable)

        :ok = InferenceCredentials.lock_source(user_id)

        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox_id)
        ])

        # The allowance's FK takes KEY SHARE on this row when first inserted.
        # UPDATE also fences that first insert when there is no allowance row
        # to lock yet. Keep both locks through the turn insert.
        conv =
          Repo.one(
            from c in Conversation,
              where: c.id == ^conv_id,
              select: %{
                id: c.id,
                user_id: c.user_id,
                configuration_revision: c.configuration_revision,
                inference_source: c.inference_source
              },
              lock: "FOR UPDATE"
          ) || Repo.rollback(:sandbox_unavailable)

        if conv.user_id != user_id, do: Repo.rollback(:sandbox_unavailable)

        # A serving actor must agree with the persisted binding. Hold the source
        # lock through insertion so replacement cannot race turn admission.
        if Map.has_key?(attrs, :inference_source) and
             attrs.inference_source != conv.inference_source do
          Repo.rollback(:inference_source_changed)
        end

        if source = Source.load(conv.inference_source) do
          with :ok <- InferenceCredentials.validate_source(user_id, source),
               :ok <- Fountain.PlatformInference.gate_source(source) do
            :ok
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        attrs = Map.put(attrs, :inference_source, conv.inference_source)

        # The server passes the revision it loaded. A reapply committed since
        # then means this turn would run against settings the server has not
        # read, so it is refused here rather than started wrong (#1565). A
        # caller with no revision to offer is not checked.
        if not is_nil(revision) and conv.configuration_revision != revision do
          # A configuration reload acknowledges the prompt before continuing.
          # An unresolved execution must refuse it while the caller can still
          # hear that refusal (#2009).
          # ownership: the caller owns this conversation; its parent lock
          # above serializes this read with journal changes.
          if ExecutionGuard._unsafe_open_execution?(conv_id),
            do: Repo.rollback(:execution_fenced)

          Repo.rollback(:configuration_changed)
        end

        # Row-only retirement writers do not take the admission advisory
        # lock. Hold their row through insertion too: a committed retirement
        # refuses admission, while a later forced retirement follows the turn.
        attached? =
          Repo.exists?(
            from c in Conversation,
              join: s in Sandbox,
              on: s.id == c.sandbox_id,
              where:
                c.id == ^conv_id and s.id == ^sandbox_id and c.user_id == s.user_id and
                  s.status not in ["terminated", "failed"] and is_nil(s.reset_requested_at),
              lock: "FOR SHARE"
          )

        unless attached?, do: Repo.rollback(:sandbox_unavailable)

        # A terminated or failed parent takes no more turns. `attached?` above
        # checks the machine; this checks the conversation, which a retired
        # actor can still reach with a queued prompt.
        if Repo.exists?(
             from c in Conversation,
               where: c.id == ^conv_id and c.status in ["terminated", "failed"]
           ),
           do: Repo.rollback(:not_running)

        case _unsafe_check_saved_execution_allowance(conv_id) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        if capacity != :unbounded and
             _unsafe_running_turns_elsewhere(sandbox_id, conv_id) >= capacity do
          Repo.rollback(:sandbox_at_capacity)
        else
          # An earlier bounded execution that is still unresolved fences this
          # conversation: a stale deadline must not be able to terminate a
          # process a successor has started using (ADR 0046). The parent is
          # already locked above, so this is a plain read.
          #
          # ownership: conv_id was proved attached to this tenant's sandbox by
          # the `attached?` check above, under the same locks.
          if ExecutionGuard._unsafe_open_execution?(conv_id),
            do: Repo.rollback(:execution_fenced)

          turn =
            case %Turn{} |> Turn.changeset(attrs) |> Repo.insert() do
              {:ok, turn} -> turn
              {:error, changeset} -> Repo.rollback(changeset)
            end

          # The parent goes `running` here rather than in the launch, so a turn
          # and the conversation status that explains it commit together. A
          # reader used to be able to see a `running` turn under an `idle`
          # parent for the width of the launch, and a launch that failed left
          # the pair disagreeing. `update_all`, not `update_conversation/2`:
          # that one audits, and an audit insert must not run inside a
          # transaction (ADR 0013).
          if Map.get(attrs, :status) == "running" do
            Repo.update_all(
              from(c in Conversation,
                where: c.id == ^conv_id and c.status != "running"
              ),
              set: [status: "running", updated_at: DateTime.utc_now()]
            )
          end

          # Same transaction as the turn: a bounded turn that exists without a
          # journal row is a turn nothing can expire. `conv` is the row this
          # transaction locked.
          # ownership: conv_id came from the caller's attrs and was verified
          # attached to this tenant's sandbox above.
          conv = Repo.get!(Conversation, conv_id)
          ExecutionGuard._unsafe_register_bounded(turn, sandbox_id, conv)
          turn
        end
      end)

    record_started_turn(result)
  end

  defp record_started_turn({:ok, turn}) do
    record_turn_usage(turn)

    case Repo.get(Conversation, turn.conversation_id) do
      nil -> :ok
      conv -> broadcast_sidebar_update(conv.user_id)
    end

    {:ok, turn}
  end

  defp record_started_turn(error), do: error

  @doc """
  Save an initial resolved allowance once, scoped to its conversation owner.

  Internal persistence only: the caller must resolve trusted current ceilings
  and prove runtime support before admission. This function does not admit work
  or reset an active turn. No launch or HTTP path calls it yet. A duplicate
  fails without replacing the saved policy; use `narrow_execution_allowance/3`
  for subsequent changes. Ownership stays locked through insertion.
  """
  def create_execution_allowance(conversation_id, user_id, resolved_limits, opts \\ []) do
    result =
      Repo.transaction(fn ->
        Repo.one(
          from c in Conversation,
            where: c.id == ^conversation_id and c.user_id == ^user_id,
            select: c.id,
            lock: "FOR SHARE"
        ) || Repo.rollback(:not_found)

        case conversation_id
             |> ExecutionAllowance.new_changeset(resolved_limits)
             |> Repo.insert() do
          {:ok, allowance} -> allowance
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    with {:ok, allowance} <- result do
      record_execution_allowance_created(allowance, user_id, opts)

      {:ok, allowance}
    end
  end

  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def record_execution_allowance_created(allowance, user_id, opts) do
    Audit.record(%{
      user_id: user_id,
      action: "conversation.execution_allowance_created",
      resource_type: "conversation",
      resource_id: allowance.conversation_id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "controls" => Enum.filter(ExecutionLimits.keys(), &Map.has_key?(allowance.limits, &1))
      }
    })
  end

  @doc """
  Narrow an existing allowance owned by `user_id`, retaining omitted controls.

  This edits future policy only: it neither admits work nor resets an active
  turn's usage/deadline. Initial allowance creation and current-ceiling checks
  remain admission responsibilities. Missing and foreign records return the
  same error. Concurrent writers revalidate against the latest locked value.
  """
  def narrow_execution_allowance(conversation_id, user_id, request, opts \\ []) do
    result =
      Repo.transaction(fn ->
        # Keep ownership stable through the write; turn admission locks this
        # conversation before its allowance too. No sandbox/provider work here.
        Repo.one(
          from c in Conversation,
            where: c.id == ^conversation_id and c.user_id == ^user_id,
            select: c.id,
            lock: "FOR SHARE"
        ) || Repo.rollback(:not_found)

        allowance =
          Repo.one(
            from a in ExecutionAllowance,
              where: a.conversation_id == ^conversation_id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        unless is_map(allowance.limits),
          do: Repo.rollback({:execution_limits_invalid, "object_required"})

        changeset = ExecutionAllowance.narrow_changeset(allowance, request)

        write =
          if changeset.valid? and not Map.has_key?(changeset.changes, :limits),
            do: {:ok, allowance},
            else: Repo.update(changeset)

        case write do
          {:ok, updated} ->
            changed =
              Enum.filter(ExecutionLimits.keys(), &(updated.limits[&1] != allowance.limits[&1]))

            {updated, changed}

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    with {:ok, {updated, changed}} <- result do
      if changed != [] do
        Audit.record(%{
          user_id: user_id,
          action: "conversation.execution_allowance_narrowed",
          resource_type: "conversation",
          resource_id: conversation_id,
          actor: Keyword.get(opts, :actor, "self"),
          request_ip: Keyword.get(opts, :request_ip),
          metadata: %{"changed" => changed}
        })
      end

      {:ok, updated}
    end
  end

  @doc """
  Refuse saved allowances that this deployment cannot enforce. Internal callers
  must establish conversation ownership first. Outside turn admission this is
  only a preflight; the turn transaction rechecks under its row locks.
  """
  def _unsafe_check_saved_execution_allowance(conversation_id) do
    case Repo.one(
           from a in ExecutionAllowance,
             where: a.conversation_id == ^conversation_id,
             lock: "FOR SHARE"
         ) do
      nil ->
        :ok

      %ExecutionAllowance{limits: limits} when is_map(limits) ->
        with {:ok, normalized} <- ExecutionLimits.normalize(limits) do
          ExecutionLimits.require_controls(normalized, ExecutionLimits.enforced_controls(nil))
        end

      _ ->
        {:error, {:execution_limits_invalid, "object_required"}}
    end
  end

  @doc """
  How many turns are running right now on `sandbox_id` for conversations
  other than `conv_id`. `_unsafe_`: the caller owns `conv_id`.
  """
  def _unsafe_running_turns_elsewhere(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id == ^sandbox_id and c.id != ^conv_id and t.status == "running",
        select: count(t.id)
    )
  end

  # No conversation to exclude: every running turn on the machine counts.
  def _unsafe_running_turns_elsewhere(sandbox_id, nil) when is_binary(sandbox_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id == ^sandbox_id and t.status == "running",
        select: count(t.id)
    )
  end

  @doc """
  Whether `sandbox_id` cannot take another turn from `conv_id` because other
  conversations already fill its runtime's capacity. Always false for
  `:unbounded`. An unlocked read for the API door; the locked check is
  `_unsafe_create_turn_on_sandbox/3`.
  """
  def _unsafe_sandbox_at_capacity?(_sandbox_id, _conv_id, :unbounded), do: false

  def _unsafe_sandbox_at_capacity?(sandbox_id, conv_id, capacity)
      when is_integer(capacity) and (is_binary(conv_id) or is_nil(conv_id)) do
    _unsafe_running_turns_elsewhere(sandbox_id, conv_id) >= capacity
  end

  @doc """
  Every conversation still holding `sandbox_id` — not `terminated` or
  `failed` — as ids: for a machine event that belongs on all of their
  transcripts, such as the checkpoint a park records.
  """
  def _unsafe_list_holder_ids(sandbox_id) when is_binary(sandbox_id) do
    Repo.all(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id and c.status not in ["terminated", "failed"],
        select: c.id
    )
  end

  @doc """
  The other conversations still holding `sandbox_id` — not `terminated` or
  `failed` — as ids: the machine's co-tenants, for a lifecycle decision one
  of them is about to make for all of them.

  The same reading of the machine as the predicates above and below it
  (`Fountain.Machines.Occupancy`, ADR 0058 stage 4), returned as a list rather
  than a verdict.
  """
  def _unsafe_list_cotenant_ids(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    sandbox_id |> Occupancy.bindings() |> Occupancy.cotenant_ids(conv_id)
  end

  @doc """
  `_unsafe_list_cotenant_ids/2`, with the identity each co-tenant declares:
  `{id, environment_id, vault_id}`, where the environment is the *effective*
  one a machine would be built from — the conversation's own override, and
  the agent's environment when it has none. That is the pair a sandbox row
  carries and `_unsafe_find_home/4` looks a home up by.

  Co-tenants normally share one identity, because attaching to a machine
  requires the same agent, environment and vault. They can diverge afterwards:
  rebinding a teammate moves one conversation's environment or vault while its
  co-tenants keep theirs. A lifecycle decision taken for the whole machine has
  to read this rather than assume, or a replacement built for one identity is
  handed to a conversation that declared another.
  """
  def _unsafe_list_cotenants_with_identity(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.all(
      from c in Conversation,
        # Fully qualified: `alias Fountain.Agents` is declared further down
        # this module, so it is not in scope here.
        left_join: a in Fountain.Agents.Agent,
        on: a.id == c.agent_id,
        where:
          c.sandbox_id == ^sandbox_id and c.id != ^conv_id and
            c.status not in ["terminated", "failed"],
        select: {c.id, coalesce(c.environment_id, a.environment_id), c.vault_id}
    )
  end

  @doc """
  Whether any *other* conversation on `sandbox_id` is mid-turn, or was active
  within the last `idle_seconds`.

  A server that finds its own conversation idle asks this before parking the
  machine everyone is on: the idle verdict is the machine's, taken over the
  union of its conversations' activity (ADR 0023 step 5), not one
  conversation's clock. Activity is a co-tenant's newest turn row (start or
  end), falling back to the conversation's own `updated_at` for one that
  never took a turn — the same fold `SandboxReaper.last_activity_at/1` makes
  for a sandbox with no server at all. `nil` idle seconds (the bound is off)
  is never busy.

  The query and the verdict both live in `Fountain.Machines.Occupancy` (ADR
  0058 stage 4), which is the one answer to "is anyone here" that
  `Lifecycle._unsafe_sandbox_held_by_other?/2` and the two liveness scans also
  take. The semantics that separate them stay separate: this one applies the
  idle window, and `held_by_other?/2` deliberately does not.

  Still the same two short-circuiting `EXISTS` probes over the co-tenants that
  it has always run — this sits on the conversation server's lifecycle tick,
  so it takes `Occupancy`'s by-id form rather than loading the whole machine.
  """
  def _unsafe_sandbox_busy_elsewhere?(
        sandbox_id,
        conv_id,
        idle_seconds,
        now \\ DateTime.utc_now()
      )

  def _unsafe_sandbox_busy_elsewhere?(_sandbox_id, _conv_id, nil, _now), do: false

  def _unsafe_sandbox_busy_elsewhere?(sandbox_id, conv_id, idle_seconds, now)
      when is_integer(idle_seconds) do
    Occupancy.busy_elsewhere?(sandbox_id, conv_id, idle_seconds, now)
  end

  # Turns carry no user_id of their own, so resolve it through the conversation.
  # One narrow select per turn, and turns are prompt-frequency rather than
  # request-frequency, so this is not a hot path.
  defp record_turn_usage(%Turn{} = turn) do
    case Repo.one(from c in Conversation, where: c.id == ^turn.conversation_id, select: c.user_id) do
      nil ->
        :ok

      user_id ->
        Fountain.Billing.record_usage(user_id, "turn_started", turn.id, "turn", %{
          "conversation_id" => turn.conversation_id,
          "turn_number" => turn.turn_number
        })
    end
  end

  @doc """
  Update a turn's row. When the update ends the turn — its status becomes
  `completed`, `failed` or `interrupted` — the assistant's text for the
  turn is materialised into `reply_text` in the same write (#826). Conditional
  completion and orphan reconciliation also materialize the reply in their
  transactions. A turn that already carries a `reply_text` keeps it.

  The same write is where activation is decided (ADR 0038): a turn that ends
  carrying a reply is handed to `Fountain.Activation.turn_replied/1`, which
  does nothing unless it is the account's *first*. Same choke-point argument,
  same best-effort contract — it cannot fail this update.
  """
  def _unsafe_update_turn(%Turn{} = turn, attrs) do
    # ownership: this is the already-owned actor's turn or a system recovery write.
    result =
      Fountain.Conversations.ExecutionGuard._unsafe_write_turn(turn, attrs, fn current, allowed ->
        changeset = current |> Turn.changeset(allowed) |> maybe_put_reply_text(current)

        case Repo.update(changeset) do
          {:ok, updated} -> {:ok, {updated, changeset}}
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, {updated, changeset}} ->
        if is_binary(Ecto.Changeset.get_change(changeset, :reply_text)) do
          Fountain.Activation.turn_replied(updated)
        end

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Complete a running turn only on the actor's current sandbox binding.

  Lock the conversation, execution journal and turn in that order, and commit
  the journal's outcome with the reply and parent idle status. A moved or
  terminal conversation is a no-op. An already-ended current turn can release
  its parent without announcing another terminal event. Reply materialization
  shares that transaction;
  activation and sidebar publication run after it commits. The optional
  `:exit_code` is persisted atomically with the result.

  Only the latest generation can idle a running parent, and a journal must
  have retired its execution first. A refused journal transition returns its
  error without changing the turn, reply or parent.

  `"interrupted"` is a terminal status this writer accepts, because a bounded
  turn that its journal retires comes back through the same ending
  (`BoundedTurn.retire/2` hands `finish/4` the persisted status, ADR 0046).
  The two-phase interrupt the server drives itself is a different write, and
  it keeps the conversation running until the peer has stopped.
  """
  def _unsafe_complete_turn(%Turn{} = turn, sandbox_id, status, opts \\ [])
      when status in ["completed", "failed", "interrupted"] do
    end_running_turn(turn, sandbox_id, status, true, Map.new(Keyword.take(opts, [:exit_code])))
  end

  # Door for `Fountain.Conversations.Interruption` (#2213), which shares this
  # helper with `_unsafe_complete_turn/4` above and so cannot move with it.
  @doc false
  def end_running_turn(turn, sandbox_id, status, idle?, attrs \\ %{}) do
    # ownership: the actor supplied its original turn and sandbox binding.
    result =
      ExecutionGuard._unsafe_end_actor_turn(turn, sandbox_id, status, attrs, fn conv, ending ->
        changeset = Turn.changeset(ending.turn, ending.attrs)

        changeset =
          if ending.materialize?,
            do: maybe_put_reply_text(changeset, ending.turn),
            else: changeset

        updated = Repo.update!(changeset)

        # Completion releases only its newest ended generation. Interrupt keeps
        # the parent running until the peer stops and its second half idles it.
        updated_conv =
          if idle? and ending.idle_allowed? and
               updated.status in ["completed", "failed", "interrupted"] and
               conv.status == "running" and
               ExecutionGuard.latest_turn?(conv.id, turn.id),
             do: conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!(),
             else: conv

        {updated, updated_conv, is_binary(Ecto.Changeset.get_change(changeset, :reply_text)),
         ending.announce?}
      end)

    case result do
      {:ok, :noop} ->
        :noop

      {:ok, {updated, conv, reply_materialized?, announce?}} ->
        if reply_materialized?, do: Fountain.Activation.turn_replied(updated)
        if idle?, do: broadcast_sidebar_update(conv.user_id)
        if announce?, do: {:ok, updated}, else: :noop

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Finish an actor's machine-gone notification, and release a stranded parent.

  Lock the parent through the running-turn check and any idle write, as
  admission does. A deleted conversation or a newer running turn makes this a
  no-op. `:ok` says the notification is this actor's to narrate: the binding
  still names the sandbox it closed and the conversation is not terminal. A
  moved or terminal conversation answers `:noop`, so an obsolete actor emits no
  sandbox event. Publication happens after commit, and this function performs
  no provider or actor I/O.

  The idle write is not conditioned on the binding, and that is deliberate.
  Under the parent lock a `running` conversation with no running turn is not a
  legitimate transient: admission inserts the running turn and sets the parent
  `running` in one transaction under this same lock (`_unsafe_create_turn_on_sandbox/3`),
  and the two other writers of `running` (`Reattachment` and `Connection`) both
  have their running turn in hand. So that pair is a stuck row, and the sweeps
  cannot repair it — `AutonomousTurnReaper.sweep_stuck_turns/0` and
  `ExecutionGuard._unsafe_recover_turn/3` both select a running turn, and there
  is none. `_unsafe_idle_interrupted_turn/1` declines to recheck the binding for
  exactly this reason and names this function as its backstop (#2000); a
  refusal here would strand the parent with nothing left to release it.
  Releasing it is a repair, not an act of the stale actor, so it still answers
  `:noop` and publishes nothing.
  """
  def _unsafe_finish_machine_gone(conversation_id, sandbox_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")

        running_query =
          from(t in Turn, where: t.conversation_id == ^conversation_id and t.status == "running")

        with %Conversation{} = conv <- Repo.one(conversation_query),
             false <- Repo.exists?(running_query) do
          # A terminal conversation is never `running`, so this decides the
          # answer, never the write.
          current? = conv.sandbox_id == sandbox_id and conv.status not in ["terminated", "failed"]

          cond do
            conv.status == "running" ->
              idled = conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!()
              if current?, do: {:updated, idled}, else: {:released, idled}

            current? ->
              :unchanged

            true ->
              :noop
          end
        else
          _ -> :noop
        end
      end)

    case result do
      {:updated, conv} ->
        broadcast_sidebar_update(conv.user_id)
        :ok

      {:released, conv} ->
        broadcast_sidebar_update(conv.user_id)
        :noop

      :unchanged ->
        :ok

      :noop ->
        :noop
    end
  end

  @doc """
  Reconciles a turn left `running` after its server or runtime disappeared.

  The turn transition and the conversation's `running` to `idle` transition
  are conditional writes. If another process already ended the turn, this is
  a no-op rather than overwriting its result. `orphaned_at` records that the
  true end of work is unknown, which keeps the interval out of billing and
  usage attribution.

  This function is unscoped because it is called by a conversation's own
  server and by the system reaper. Callers may supply audit attribution.

  An actor recovering its own turn passes `:expected_sandbox_id`; the locked
  parent having been rebound to another sandbox answers
  `{:error, :ownership_changed}` and writes nothing. The reaper omits the key,
  because it recovers on nobody's behalf.
  """
  def _unsafe_orphan_turn(%Turn{} = turn, why, opts \\ []) do
    # ownership: this is the existing actor's turn or a system recovery candidate.
    recover_opts = Keyword.take(opts, [:expected_sandbox_id])

    result =
      ExecutionGuard._unsafe_recover_turn(
        turn,
        fn current, conv, latest?, bounded? ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          reply_text = current.reply_text || _unsafe_turn_reply_text(current)

          updates =
            if current.status == "running",
              do: [status: "interrupted", ended_at: now, orphaned_at: now],
              else: [orphaned_at: now]

          updated =
            current
            |> Turn.changeset(Map.new(maybe_set_reply_text(updates, reply_text)))
            |> Repo.update!()

          conversation_changed? = latest? and conv.status == "running"

          conv =
            if conversation_changed?,
              do: conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!(),
              else: conv

          {updated, conv, conversation_changed?, bounded?}
        end,
        recover_opts
      )

    case result do
      {:ok, :noop} ->
        :noop

      {:ok, {updated_turn, conv, conversation_changed?, bounded?}} ->
        if is_nil(turn.reply_text) and is_binary(updated_turn.reply_text) do
          Fountain.Activation.turn_replied(updated_turn)
        end

        if conversation_changed?, do: broadcast_sidebar_update(conv.user_id)

        metadata = %{
          outcome: "turn_orphaned",
          turn_id: turn.id,
          turn_number: turn.turn_number,
          reason: why
        }

        if bounded? do
          status = if updated_turn.status == "failed", do: "failed", else: "interrupted"
          publish_stage(turn.conversation_id, "turn", status, metadata)
        else
          publish_stage(turn.conversation_id, "reattach", "interrupted", metadata)
        end

        Audit.record(%{
          user_id: conv.user_id,
          action: "conversation.turn.orphaned",
          resource_type: "turn",
          resource_id: turn.id,
          actor: Keyword.get(opts, :actor, "system:conversation_server"),
          metadata: %{
            "conversation_id" => turn.conversation_id,
            "turn_number" => turn.turn_number,
            "reason" => why
          }
        })

        {:ok, updated_turn, conv}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_set_reply_text(updates, nil), do: updates

  defp maybe_set_reply_text(updates, reply_text),
    do: Keyword.put(updates, :reply_text, reply_text)

  @doc """
  Record a turn's end-of-turn token usage (#827): stamp `usage` on the turn
  and add its `input` / `output` to the conversation's running sums, in one
  transaction. `usage` is the normalised map `Managoat.ACP.Usage`
  produces (`%{"input" => n, "output" => n, ...}`); nil records nothing.

  Once per turn, by the ConversationServer when the `session/prompt`
  response arrives — never from the live `usage_update`s, whose meaning
  differs per runtime (a per-call delta, a thread total, a per-step figure).
  A second call for the same turn would double-count the conversation, so
  it refuses when the turn already carries a usage.

  The one usage map that is not an end-of-turn record is the turn-start
  inference stamp (#1685): it carries no token figure, so it has counted
  towards nothing and there is nothing to double. This write merges over it
  — the stamp's keys are the two `TurnMachine.with_inference/2` writes here
  as well, so a turn that answers its prompt ends with the map it would have
  carried with no stamp at all.
  """
  def _unsafe_record_turn_usage(%Turn{}, nil), do: :ok

  def _unsafe_record_turn_usage(%Turn{usage: %{} = recorded} = turn, %{} = usage) do
    if Turn.inference_stamp_only?(recorded),
      do: write_turn_usage(turn, Map.merge(recorded, usage)),
      else: {:error, :already_recorded}
  end

  def _unsafe_record_turn_usage(%Turn{} = turn, %{} = usage), do: write_turn_usage(turn, usage)

  defp write_turn_usage(%Turn{} = turn, %{} = usage) do
    # `usage` is whatever the runtime reported. The map is stored as it came,
    # but the counters it increments are bigints: a string or an object here
    # used to raise inside the transaction and take the turn's usage
    # recording with it. Anything that is not a non-negative integer counts
    # as nothing, which is what an unreported figure already counts as.
    Repo.transaction(fn ->
      # Same parent-before-turn lock order as ExecutionGuard. Delayed accounting
      # survives retirement, but duplicate deliveries cannot debit twice.
      Repo.one(from c in Conversation, where: c.id == ^turn.conversation_id, lock: "FOR UPDATE") ||
        Repo.rollback(:not_found)

      current =
        Repo.one(
          from t in Turn,
            where: t.id == ^turn.id and t.conversation_id == ^turn.conversation_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:not_found)

      # The row read under the lock is what decides, not the one the caller
      # matched on — that is the whole point of re-reading it. But `usage` is
      # not only a figure: a turn carries an inference stamp from the moment
      # it starts (#1685), which is a map and is not a recorded usage. Refuse
      # a real second figure, and merge over a stamp exactly as
      # `_unsafe_record_turn_usage/2` does on the unlocked read above.
      # Checking `is_map/1` alone refused every stamped turn, which is every
      # turn on platform inference.
      usage =
        cond do
          is_nil(current.usage) -> usage
          Turn.inference_stamp_only?(current.usage) -> Map.merge(current.usage, usage)
          true -> Repo.rollback(:already_recorded)
        end

      # Read from the merged map because that is what gets stored; the two
      # agree either way, since the only map the merge folds in is a stamp and
      # a stamp carries no counter. Do not read this as defending against a
      # stamp that grows one — if that were possible the merge would debit it
      # here and again when the real figure landed, so the ordering would be
      # the bug rather than the guard.
      #
      # `usage` is whatever the runtime reported. The map is stored as it came,
      # but the counters it increments are bigints: a string or an object here
      # used to raise inside the transaction and take the turn's usage
      # recording with it. Anything that is not a non-negative integer counts
      # as nothing, which is what an unreported figure already counts as.
      input = counter_value(Map.get(usage, "input"))
      output = counter_value(Map.get(usage, "output"))

      {:ok, updated} = current |> Turn.changeset(%{usage: usage}) |> Repo.update()

      {1, _} =
        Repo.update_all(
          from(c in Conversation, where: c.id == ^turn.conversation_id),
          inc: [usage_input_tokens: input, usage_output_tokens: output]
        )

      updated
    end)
  end

  defp counter_value(n) when is_integer(n) and n >= 0, do: n
  defp counter_value(_), do: 0

  @terminal_turn_statuses ~w(completed failed interrupted)

  defp maybe_put_reply_text(%Ecto.Changeset{valid?: false} = changeset, _turn), do: changeset

  # `get_field`, not `get_change`: a turn fenced by `ExecutionGuard` has its
  # `:status` dropped from `attrs` before the writer sees it, so the change is
  # gone by here while the row is already terminal — and a turn that ends at a
  # deadline would have kept a null `reply_text` forever.
  #
  # This does reach the unbounded path, where the two used to agree: a terminal
  # turn whose text is still null is now re-derived on each later write rather
  # than only on the write that ended it. That is the same work
  # `_unsafe_backfill_reply_texts/0` below does, on the same rows, for the same
  # reason — a turn whose assistant blocks landed after its status did. The
  # guard is `reply_text: nil`, so a turn that has one is never revisited.
  defp maybe_put_reply_text(changeset, %Turn{reply_text: nil} = turn) do
    case Ecto.Changeset.get_field(changeset, :status) do
      status when status in @terminal_turn_statuses ->
        Ecto.Changeset.put_change(changeset, :reply_text, _unsafe_turn_reply_text(turn))

      _ ->
        changeset
    end
  end

  defp maybe_put_reply_text(changeset, _turn), do: changeset

  @doc """
  Materialise `reply_text` on every ended turn that has none — the one-time
  backfill for turns that predate the column (`Fountain.Release.backfill_turn_replies/0`).
  Returns the number of turns written; a turn with no assistant text is
  left null and visited again next run (there are few, and re-parsing them
  is cheap). No tenant scope: a system sweep.
  """
  def _unsafe_backfill_reply_texts do
    from(t in Turn,
      where: t.status in ^@terminal_turn_statuses and is_nil(t.reply_text),
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
    |> Enum.reduce(0, fn turn, n ->
      case _unsafe_turn_reply_text(turn) do
        nil ->
          n

        text ->
          {:ok, _} = turn |> Turn.changeset(%{reply_text: text}) |> Repo.update()
          n + 1
      end
    end)
  end

  @doc """
  The assistant's text for `turn`, from its events through the same parse
  the transcript uses (`Blocks.assistant_text/1`); nil when there is none.
  Without tenant scope: the caller holds the turn.
  """
  def _unsafe_turn_reply_text(%Turn{} = turn) do
    case turn.id |> _unsafe_list_turn_log_events() |> Blocks.assistant_text() do
      "" -> nil
      text -> text
    end
  end

  # ── log events ──────────────────────────────────────────────────────────────────────────

  @doc """
  Total persisted bytes of `kind: "output"` log data for a conversation.
  Without tenant scoping — the caller is the conversation's own server,
  seeding the durable-output budget (#331).
  """
  def _unsafe_output_byte_total(conversation_id) do
    Repo.one(
      from(l in LogEvent,
        where: l.conversation_id == ^conversation_id and l.kind == "output",
        select: coalesce(sum(fragment("octet_length(?)", l.data)), 0)
      )
    )
  end

  @doc """
  Insert a log event. Returns the inserted struct (with integer `:id`,
  used as the SSE event id), or nil for output from a retired bounded turn.
  Stage callers use `publish_stage/4`; the deadline journal inserts its own
  terminal event while holding the same locks.
  """
  def log!(attrs) do
    # Microsecond precision so the LiveView can compute stage durations
    # under 1s (provision steps run in tens of ms).
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now())

    # Redact here rather than at the call sites. Sprite output is persisted
    # verbatim and log_events has none of the encryption the secret itself has,
    # so a path that forgets to scrub writes plaintext credentials to a table
    # that outlives the conversation. Doing it at the single writer means a new
    # log path is covered whether or not its author knew to.
    attrs = redact_attrs(attrs)

    # The writer is main's ordered insert (#1706), not a bare `Repo.insert!`:
    # a bounded turn's output still has to take the account's SSE cursor lock,
    # or its events can commit out from behind the cursor and never be seen.
    writer = fn -> %LogEvent{} |> LogEvent.changeset(attrs) |> insert_ordered_log_event!() end

    # LOCK ORDER, before the call below: on the bounded path
    # `_unsafe_write_event/3` already holds the conversation, journal and turn
    # rows `FOR UPDATE`, so the advisory lock inside
    # `insert_ordered_log_event!/1` is taken *after* those rows, while every
    # other log-event write takes it *before* touching the conversation (its
    # insert needs `KEY SHARE` on that row through the foreign key). Two
    # writers on one account can therefore take these in opposite orders.
    # Postgres aborts one rather than hanging, and the path is unreachable
    # while no execution ceiling can be set, but the inversion is real.
    if attrs[:kind] == "output" do
      # ownership: callers supply the owned conversation and exact output turn.
      {:ok, event} =
        ExecutionGuard._unsafe_write_event(attrs[:conversation_id], attrs[:turn_id], writer)

      event
    else
      writer.()
    end
  end

  defp insert_ordered_log_event!(%Ecto.Changeset{valid?: true} = changeset) do
    conversation_id = Ecto.Changeset.get_field(changeset, :conversation_id)

    {:ok, event} =
      Repo.transaction(fn ->
        # Account SSE cursors advance by id. Allocate that id only after all
        # earlier writes for this account commit, including other conversations
        # and outer transactions. Otherwise N+1 can commit first and hide N
        # forever behind the cursor (#1706). Other accounts have separate locks.
        Repo.query!(
          "SELECT pg_advisory_xact_lock($1, hashtext(user_id::text)) " <>
            "FROM conversations WHERE id = $2",
          [@log_event_lock_namespace, Ecto.UUID.dump!(conversation_id)]
        )

        Repo.insert!(changeset)
      end)

    event
  end

  defp insert_ordered_log_event!(changeset), do: Repo.insert!(changeset)

  defp redact_attrs(%{conversation_id: conv_id, data: data} = attrs)
       when is_binary(conv_id) and is_binary(data) do
    %{attrs | data: Fountain.Conversations.Redaction.redact(conv_id, data)}
  end

  defp redact_attrs(attrs), do: attrs

  @doc """
  Record a stage transition: persist the log event, broadcast it to the
  conversation's PubSub topic, and emit a `[:fountain, :stage]` telemetry
  event.

  Deadline outcomes are persisted by the journal and notified by a durable job.
  A late terminal stage reuses that event, or returns nil if retention deleted
  it. Notifications are at-least-once; clients deduplicate by the log event id.
  `stage` and `status` are the metric's only tags; both value sets are small
  and fixed. `conv_id` stays in metadata and must never become a tag.
  """
  def publish_stage(conv_id, stage, status, meta \\ %{}) do
    turn_id = Map.get(meta, :turn_id) || Map.get(meta, "turn_id")

    writer = fn ->
      log!(%{
        conversation_id: conv_id,
        turn_id: turn_id,
        kind: "stage",
        stage: stage,
        state: status,
        data: Jason.encode!(meta)
      })
    end

    result =
      if stage == "turn" and status in ["done", "failed", "interrupted"] and
           match?({:ok, _}, Ecto.UUID.cast(turn_id)) do
        # ownership: lifecycle caller owns conv_id; the journal query binds this
        # turn to that conversation and serializes it with deadline expiration.
        {:ok, result} = ExecutionGuard._unsafe_terminal_stage(conv_id, turn_id, status, writer)
        result
      else
        {:ok, event} = ExecutionGuard._unsafe_write_event(conv_id, turn_id, writer)
        {:new, event}
      end

    case result do
      {:new, nil} ->
        nil

      {:existing, event} ->
        event

      {:new, event} ->
        notify_stage(event, meta)
        Fountain.Webhooks.dispatch_stage(event)
        event
    end
  end

  @doc "Notify subscribers of an existing stage; deadline jobs may repeat its id."
  def _unsafe_notify_stage(%LogEvent{kind: "stage"} = event) do
    meta =
      case Jason.decode(event.data) do
        {:ok, meta} when is_map(meta) -> meta
        _ -> %{}
      end

    notify_stage(event, meta)
  end

  defp notify_stage(event, meta) do
    conv_id = event.conversation_id
    stage = event.stage
    status = event.state

    Fountain.Telemetry.event(
      [:stage],
      %{stage: stage, status: status, conv_id: conv_id},
      %{count: 1}
    )

    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, event})

    mirror_stage_to_analytics(event, meta)

    event
  end

  # Which stage outcomes are product events, and why only these.
  #
  # Provisioning already reaches PostHog through `Billing.record_usage/5`
  # (`usage.sandbox_provisioned` and friends), which carries the user id for
  # free — mirroring it here as well would double-count the same fact. What
  # metering does *not* have is how a turn ended, and "how many turns finished,
  # and how many of those failed" is the single most useful thing this system
  # can report about itself. The two failure stages join it because they are
  # the ones that end an activation attempt.
  @analytics_stages %{
    {"turn", "done"} => true,
    {"turn", "failed"} => true,
    {"turn", "interrupted"} => true,
    {"setup", "failed"} => true,
    {"model", "failed"} => true
  }

  defp mirror_stage_to_analytics(event, meta) do
    # `enabled?/0` first, before anything touches the database. This runs on
    # the conversation hot path, and an instance with no PostHog key must not
    # pay a query for a feature it has not turned on.
    with true <- Fountain.Analytics.enabled?(),
         true <- Map.has_key?(@analytics_stages, {event.stage, event.state}),
         user_id when is_binary(user_id) <- conversation_user_id(event.conversation_id) do
      Fountain.Analytics.capture(
        "conversation.#{event.stage}.#{event.state}",
        user_id,
        meta
        |> Fountain.Analytics.sanitize()
        |> Map.merge(%{
          "conversation_id" => event.conversation_id,
          "source" => "conversation"
        })
      )
    else
      _ -> :ok
    end
  rescue
    # Same contract as the webhook dispatch above it: a stage transition that
    # raises is a stuck agent, and analytics is never worth that.
    _ -> :ok
  end

  defp conversation_user_id(nil), do: nil

  defp conversation_user_id(conversation_id) do
    Repo.one(from c in Conversation, where: c.id == ^conversation_id, select: c.user_id)
  end

  @doc """
  One turn's log events, oldest first — the events a single reply is rendered
  from. Ownership rides on the turn: reach it through a tenant-scoped
  conversation first.
  """
  def _unsafe_list_turn_log_events(turn_id) when is_binary(turn_id) do
    Repo.all(from e in LogEvent, where: e.turn_id == ^turn_id, order_by: [asc: e.id])
  end

  @doc """
  The id of a conversation's newest log event, or `0` when it has none.

  A cursor for "everything from here on", which is what a caller about to
  prompt a live conversation needs: the events its own turn produces, without
  the ones a previous turn already wrote. Ownership rides on the conversation —
  reach it through a tenant-scoped fetch first.
  """
  @spec _unsafe_latest_log_event_id(String.t()) :: integer()
  def _unsafe_latest_log_event_id(conversation_id) when is_binary(conversation_id) do
    from(e in LogEvent,
      where: e.conversation_id == ^conversation_id,
      select: max(e.id)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  List a conversation's log events after `after_id`, oldest first.

  Options:

    * `:streams` — allow-list of `"stdout"` / `"stderr"` / `"stage"`
    * `:limit` — cap the number of rows returned. A log feed is unbounded
      in principle (a chatty agent writes tens of thousands of rows), so
      the JSON read-model paginates rather than materialising all of it.
  """
  def _unsafe_list_log_events(conversation_id, after_id \\ 0, opts \\ []) do
    base =
      from e in LogEvent,
        where: e.conversation_id == ^conversation_id and e.id > ^after_id,
        order_by: [asc: e.id]

    base
    |> apply_streams_filter(Keyword.get(opts, :streams))
    |> apply_limit(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc "The newest durable event cursor across this user's conversations, or zero."
  def latest_user_log_event_id(user_id) when is_binary(user_id) do
    user_log_events_query(user_id)
    |> select([e], max(e.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Durable events after a user's cursor, including conversations that have finished.
  Returns at most 500 rows in id order.
  """
  def list_user_log_events(user_id, after_id) when is_binary(user_id) do
    user_log_events_query(user_id)
    |> where([e], e.id > ^after_id)
    |> order_by([e], asc: e.id)
    |> limit(500)
    |> select([e], e)
    |> Repo.all()
  end

  defp user_log_events_query(user_id) do
    from e in LogEvent,
      join: c in Conversation,
      on: c.id == e.conversation_id,
      where: c.user_id == ^user_id
  end

  defp apply_limit(query, nil), do: query

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0,
    do: from(e in query, limit: ^limit)

  # `streams` is a list of allowed stream identifiers: any value of the
  # `stream` column, plus `"stage"`, the synthetic name for `kind: "stage"`
  # events (which have no `stream` value of their own). `nil`/empty list =
  # no filter.
  #
  # There is deliberately **no allow-list of stream names**. There used to be
  # one — `["stdout", "stderr"]`, written when those were the only two — and
  # when ACP added a third (`"acp"`, one stored `session/update` per line) the
  # filter silently answered "nothing" for it: an unrecognised name fell to a
  # `where: false`. A name we do not know is now simply a name no row has,
  # which returns nothing on its own without a list to keep in step.
  #
  # `event_in_streams?/2` is the same rule for an event already in hand. The
  # two must agree — see the test that runs one table through both. They did
  # not agree before, and the gap was invisible in exactly the way that hurts:
  # live events matched, replayed ones did not, so a filtered stream returned
  # a conversation's future and none of its past.
  defp apply_streams_filter(query, nil), do: query
  defp apply_streams_filter(query, []), do: query

  defp apply_streams_filter(query, streams) when is_list(streams) do
    real_streams = Enum.reject(streams, &(&1 == "stage"))
    include_stage? = "stage" in streams

    cond do
      include_stage? and real_streams != [] ->
        from e in query,
          where: e.kind == "stage" or e.stream in ^real_streams

      include_stage? ->
        from e in query, where: e.kind == "stage"

      true ->
        from e in query, where: e.stream in ^real_streams
    end
  end

  @doc """
  Whether one already-loaded event belongs to a `?streams=` selection.

  The in-memory half of `apply_streams_filter/2`, used for events arriving
  live over PubSub, where there is no query to add a `where` to. It lives here
  rather than in the controller so the two halves of one rule sit together and
  are tested together.
  """
  @spec event_in_streams?(LogEvent.t(), [String.t()] | nil) :: boolean()
  def event_in_streams?(_ev, nil), do: true
  def event_in_streams?(_ev, []), do: true
  def event_in_streams?(%LogEvent{kind: "stage"}, streams), do: "stage" in streams

  def event_in_streams?(%LogEvent{stream: s}, streams) when is_binary(s),
    do: s in streams

  def event_in_streams?(_ev, _streams), do: false

  @doc """
  The most recent persisted output lines of one stream for a turn, as a set.

  Feeds the ACP reattach path: sprites replays the tail of the session buffer
  (measured at 16 KiB), and the peer re-encodes protocol lines so a byte count
  cannot align the replay with what is already stored — content can. `limit`
  rows is comfortably more than 16 KiB of `session/update` lines.
  """
  def _unsafe_recent_output_lines(conversation_id, turn_id, stream, limit \\ 400) do
    from(e in LogEvent,
      where:
        e.conversation_id == ^conversation_id and e.turn_id == ^turn_id and
          e.kind == "output" and e.stream == ^stream,
      order_by: [desc: e.id],
      limit: ^limit,
      select: e.data
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── high-level lifecycle ──────────────────────────────────────────────────────────

  alias Fountain.Agents
  alias Fountain.Conversations.ConversationServer

  # No runtime has integrated end-to-end enforcement yet. Refuse a requested
  # control before reserving capacity, attaching or unbinding a channel; an
  # SDK option alone must not make admission promise a bounded execution.
  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def check_execution_limits(user_id, request) do
    with {:ok, _limits} <- resolve_admission_limits(user_id, request), do: :ok
  end

  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def resolve_admission_limits(user_id, request) do
    # Ownership: each caller just fetched the agent by this authenticated user.
    # Read the current account policy, never a request-supplied or cached map.
    case {Fountain.Accounts.get_user(user_id), ExecutionLimits.host_ceiling()} do
      {%Fountain.Accounts.User{execution_limits: ceiling}, host}
      when is_map(ceiling) and is_map(host) ->
        with {:ok, limits} <- ExecutionLimits.resolve(host, ceiling, request),
             :ok <-
               ExecutionLimits.require_controls(limits, ExecutionLimits.enforced_controls(nil)) do
          {:ok, limits}
        end

      {nil, _} ->
        {:error, :not_found}

      _ ->
        {:error, {:execution_limits_invalid, "object_required"}}
    end
  end

  # A resume lands on the conversation the binding already has, so labels on
  # the request are merged into it rather than dropped (#1637). A caller that
  # sends none changes nothing, and the resume stays the silent path it was.
  #
  # The same scoped ownership rule as set_conversation_labels/4, applied to
  # the row resume_channel read under admission's source lock. Keep the audit
  # outside that transaction so a failed audit cannot undo a successful resume.
  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def resume_labels(%Conversation{} = conv, nil, _opts), do: {:ok, conv, nil}

  def resume_labels(%Conversation{} = conv, labels, opts) do
    if sandbox_owns?(conv, Keyword.get(opts, :sandbox_key_id)),
      do: merge_labels(conv, labels),
      else: {:error, :sprite_may_not_label_another_conversation}
  end

  @doc """
  The live home of an agent identity — the one persistent sandbox for
  `(user, agent, environment, vault)` that is not terminated or failed — or
  nil. `nil` environment and vault are part of the identity, not wildcards.
  `_unsafe_`: callers have resolved the agent tenant-scoped already.
  """
  def _unsafe_find_home(user_id, agent_id, env_id, vault_id)
      when is_binary(user_id) and is_binary(agent_id) do
    from(s in Sandbox,
      where:
        s.user_id == ^user_id and s.agent_id == ^agent_id and s.mode == "persistent" and
          s.status not in ["terminated", "failed"],
      order_by: [desc: s.inserted_at],
      limit: 1
    )
    |> where_sandbox_environment(env_id)
    |> where_sandbox_vault(vault_id)
    |> Repo.one()
  end

  defp where_sandbox_vault(query, nil), do: from(s in query, where: is_nil(s.vault_id))
  defp where_sandbox_vault(query, id), do: from(s in query, where: s.vault_id == ^id)

  defp where_sandbox_environment(query, nil),
    do: from(s in query, where: is_nil(s.environment_id))

  defp where_sandbox_environment(query, id), do: from(s in query, where: s.environment_id == ^id)

  @doc """
  Every live home built on `environment_id`, across the agents that name it.
  `_unsafe_`: the caller owns the environment, and a home carries the same
  `user_id` as the environment its identity names.
  """
  def _unsafe_homes_for_environment(environment_id) when is_binary(environment_id) do
    live_homes(from(s in Sandbox, where: s.environment_id == ^environment_id))
  end

  @doc """
  Every live home built on `vault_id`. Same ownership note as
  `_unsafe_homes_for_environment/1`.
  """
  def _unsafe_homes_for_vault(vault_id) when is_binary(vault_id) do
    live_homes(from(s in Sandbox, where: s.vault_id == ^vault_id))
  end

  @doc """
  The homes of `agent_id` that moving it to `env_id` orphans: built for a
  different environment, so the next launch looks under the new identity key,
  finds nothing and provisions a fresh machine while these stay `ready` —
  holding a concurrency slot and a disk with the old environment's secrets on
  it (#1084). `nil` is an environment like any other here: an agent that
  loses its environment orphans the homes that had one.
  """
  def _unsafe_homes_orphaned_by_environment(agent_id, env_id) when is_binary(agent_id) do
    from(s in Sandbox, where: s.agent_id == ^agent_id)
    |> where_environment_differs(env_id)
    |> live_homes()
  end

  defp where_environment_differs(query, nil),
    do: from(s in query, where: not is_nil(s.environment_id))

  # `!=` is null-returning in SQL, so a home with no environment has to be
  # named explicitly or it reads as "not different" and survives.
  defp where_environment_differs(query, env_id),
    do: from(s in query, where: is_nil(s.environment_id) or s.environment_id != ^env_id)

  defp live_homes(query) do
    from(s in query,
      where: s.mode == "persistent" and s.status not in ["terminated", "failed"],
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Whether any of `homes` is running a turn — asked *before* a change that
  would pull the machine out from under a working agent, so the refusal costs
  nothing (#1084). Advisory only: each retirement re-checks under the
  per-sandbox advisory lock, which is what actually makes a teardown safe.
  """
  def _unsafe_any_home_mid_turn?(homes) when is_list(homes) do
    Enum.any?(homes, &(_unsafe_running_turns_elsewhere(&1.id, nil) > 0))
  end

  @doc """
  Retire `homes` whose identity moved out from under them — the agent's
  environment changed, or the environment or vault the key names was deleted
  (#1084). Each goes through `reset_sandbox/2`, so the conversations on it are
  kept and their next prompt builds a machine on the identity that exists now.

  Best-effort per home, and deliberately so: a turn that starts between the
  caller's check and this call leaves that one machine standing rather than
  cutting the turn. The orphan is then what it was before this existed — a
  `ready` row `fountain sandbox reset` clears — and the warning says which.
  Returns the number retired.
  """
  def _unsafe_retire_orphaned_homes(homes, reason, opts \\ []) when is_list(homes) do
    Enum.count(homes, fn home ->
      case reset_sandbox(home, Keyword.put(opts, :reason, reason)) do
        {:ok, _} ->
          true

        {:error, err} ->
          Logger.warning(
            "home #{home.id} orphaned by #{reason} was left standing: #{inspect(err)}"
          )

          false
      end
    end)
  end

  @doc """
  Reset a home: destroy the agent's machine so the next launch on its
  identity builds a clean one (ADR 0023 step 5, #1071). The conversations on
  it stay — idle and resumable — because the disk was the problem, not the
  transcripts; each is told the machine is gone, so its next prompt takes the
  wake path, which provisions a fresh home and moves the others onto it.

  `sandbox` came from the caller's scoped `get_sandbox/2`, but the decision is
  made on the row re-read under the lock, not on that struct. Only a
  `persistent` sandbox that is **`ready` or `suspended`** resets: an ephemeral
  one is a conversation's own and ends with it
  (`{:sandbox_not_resettable, "ephemeral"}`), and any other status —
  `pending` and `starting` as much as `terminated` and `failed` — answers
  `{:sandbox_not_resettable, status}`. A machine still being built has no disk
  to replace and no confirmed identity to delete, so it is the provision
  watchdog's to finish, not this function's. Refused with `:sandbox_mid_turn`
  while any conversation on it runs a turn — the check and the durable reset
  fence share turn admission's advisory lock.

  A provider error or lost caller leaves the fence and capacity in place;
  repeated resets return `:sandbox_reset_pending` without another delete, and
  so does anything that would re-use the machine. **The fence is not a dead
  end.** A write that retires the row still goes through (`update_sandbox/2`),
  so an operator reaps it from `/admin/sandboxes`, deleting the agent still
  works, and account deletion still completes. Reaping is the supported way
  out of an unconfirmed reset; it terminates the row and releases the quota
  slot, and whatever the provider did or did not do with the machine is then
  the operator's to check. Pending resets also get durable deletion retries
  from `SandboxResetReconciler`; automatic retries retain capacity until the
  provider confirms deletion.

  Two audit rows, not one: `sandbox.reset_requested` when the fence commits,
  and `sandbox.reset` only when the provider confirms the destroy.

  Also refused with `:execution_fenced` while a bounded turn on this machine
  has remote work Fountain cannot account for (ADR 0046). That is a third,
  distinct fact: `:sandbox_mid_turn` is a live turn and ends by itself,
  `:sandbox_reset_pending` is a delete this function asked for and has not had
  confirmed, and `:execution_fenced` is a command that may still be running
  under a deadline whose termination was never acknowledged. It is bounded —
  the deadline coordinator writes an unresolvable obligation off — so this
  refusal clears on its own without needing the reaping the other one does.

  `opts[:reason]` says *why*, and reaches every transcript on the machine and
  the audit row: `"home_reset"` (the owner asked — the default),
  `"environment_changed"`, `"environment_deleted"`, `"vault_deleted"` or
  `"teammate_rebound"` when the identity moved out from under the home
  (#1084, #1636).

  If a retry retires the row while this call awaits the provider, this caller
  returns `{:ok, :skipped}` without repeating completion notifications.

  A fourth refusal joins the three above in ADR 0058 stage 5c:
  `:sandbox_unavailable`, when another teardown of this machine holds its
  owner's lease. It is the only one answered **after** the fence has committed,
  so it does not mean the reset was refused — the machine is fenced and
  `SandboxResetReconciler` finishes it. Sending the request again answers
  `:sandbox_reset_pending`, from the fence this call wrote.

  See `create_agent/2` for the rest of `opts` (`:actor`, `:request_ip`).
  """
  def reset_sandbox(%Sandbox{} = sandbox, opts \\ []) do
    if Repo.in_transaction?(),
      do: {:error, :provider_transaction_open},
      else: do_reset_sandbox(sandbox, opts)
  end

  defp do_reset_sandbox(sandbox, opts) do
    now = DateTime.utc_now()

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox.id)
        ])

        current =
          Repo.one(
            from s in Sandbox,
              where: s.id == ^sandbox.id and s.user_id == ^sandbox.user_id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        cond do
          current.mode != "persistent" ->
            Repo.rollback({:sandbox_not_resettable, "ephemeral"})

          current.status not in ["ready", "suspended"] ->
            Repo.rollback({:sandbox_not_resettable, current.status})

          current.reset_requested_at ->
            Repo.rollback(:sandbox_reset_pending)

          _unsafe_running_turns_elsewhere(current.id, nil) > 0 ->
            Repo.rollback(:sandbox_mid_turn)

          # ownership: `current` is the caller's scoped sandbox, re-read under
          # this transaction's lock.
          #
          # A turn that has ended locally can still owe a remote termination
          # (ADR 0046), so this outlives the running-turn check above and is a
          # different answer. Destroying the machine would drop the journal row
          # that says the command was never confirmed stopped.
          ExecutionGuard._unsafe_sandbox_open?(current.id) ->
            Repo.rollback(:execution_fenced)

          true ->
            :ok
        end

        fenced = current |> Ecto.Changeset.change(reset_requested_at: now) |> Repo.update!()

        ids =
          Repo.all(
            from c in Conversation,
              where: c.sandbox_id == ^current.id and c.status not in ["terminated", "failed"],
              select: c.id
          )

        # Admission is fenced before these sessions become unusable.
        Repo.update_all(from(c in Conversation, where: c.id in ^ids),
          set: [runtime_session_id: nil, updated_at: DateTime.truncate(now, :second)]
        )

        {fenced, ids}
      end)

    with {:ok, {fenced, ids}} <- result,
         :ok <- record_reset_requested(fenced, ids, opts),
         {:ok, %Sandbox{} = completed} <- finish_sandbox_reset(fenced) do
      record_reset_completed(completed, ids, opts)
    end
  end

  @doc """
  Retry deletion of a pending reset, leaving its fence in place until confirmed.

  Re-reads the owned row: missing rows return `:not_found`; an unfenced,
  ephemeral or already terminal sandbox is skipped. A machine whose owner
  holds a live lease answers `{:error, :sandbox_unavailable}` — another
  teardown of this machine is running, which is a retryable condition and not
  an unconfirmed deletion (ADR 0058 stage 5c). Provider I/O runs outside
  transactions, and a confirmed delete uses the normal retirement accounting,
  transcript notifications and audit event. Concurrent finalizers return
  `{:ok, :skipped}` after another caller retires the row; only the winner
  publishes completion. Repeating a completed retry does not delete again.
  The caller supplies audit attribution through `opts`. With `:reprobe`, ask
  the provider whether the machine exists first: only a definitive not-found
  or a successful delete confirms retirement; an uncertain probe keeps the fence.
  """
  def retry_pending_sandbox_reset(%Sandbox{} = sandbox, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case Repo.get_by(Sandbox, id: sandbox.id, user_id: sandbox.user_id) do
        nil ->
          {:error, :not_found}

        %Sandbox{mode: "persistent", status: status, reset_requested_at: at} = current
        when status in ["ready", "suspended"] and not is_nil(at) ->
          # Whether some owner is working on this machine right now (ADR 0058).
          # A retry is a *reconciliation* — it exists for a reset whose caller
          # was lost — so a machine another operation is holding is not its
          # business: the holder is either finishing this same reset or
          # destroying the machine outright, and either way one provider call
          # is the right number.
          #
          # `Machines.Destroy` would serialize the two anyway (the second claim
          # waits out the first and then finds the row terminal), so this is
          # not what makes the retry safe. What it buys is that the retry does
          # not burn its five second wait, and that a reconciler sweep walking
          # a backlog does not queue behind every live destroy in it.
          #
          # `Lease.live?/2` since stage 6a: this used to be a copy of the rule,
          # written here, next to two more written in SQL.
          if Lease.live?(current),
            do: {:error, :sandbox_unavailable},
            else: do_pending_reset_retry(current, opts)

        _ ->
          {:ok, :skipped}
      end
    end
  end

  defp do_pending_reset_retry(current, opts) do
    with {:ok, %Sandbox{} = completed} <- finish_sandbox_reset(current, opts) do
      opts =
        opts
        |> Keyword.put_new(:reason, "reset_reconciled")
        |> Keyword.put_new(:by, "system")

      record_reset_completed(completed, _unsafe_list_holder_ids(current.id), opts)
    end
  end

  defp record_reset_completed(completed, ids, opts) do
    reason = Keyword.get(opts, :reason, "home_reset")
    message = reset_message(reason)

    # A conversation with a live server is told through it — the server
    # cuts nothing (no turn is running), records the event on its own
    # transcript and stops. One without a server gets the event recorded
    # here, so every transcript on the home says the same thing.
    Enum.each(ids, fn id ->
      case ConversationServer.whereis(id) do
        nil ->
          publish_stage(id, "sandbox", "done", %{
            event: "reset",
            reason: reason,
            by: Keyword.get(opts, :by, "owner"),
            message: message
          })

        pid ->
          GenServer.cast(
            pid,
            {:sandbox_reset, completed.id, reason, Keyword.get(opts, :by, "owner"), message}
          )
      end
    end)

    Audit.record(%{
      user_id: completed.user_id,
      action: "sandbox.reset",
      resource_type: "sandbox",
      resource_id: completed.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "agent_id" => completed.agent_id,
        "provider" => completed.provider,
        "conversations" => length(ids),
        "reason" => reason
      }
    })

    {:ok, completed}
  end

  # The fence has committed and the sessions on the machine are already gone,
  # so this much happened whatever the provider says next. `sandbox.reset` is
  # kept for the confirmed destroy; without this row an unconfirmed reset
  # changes tenant state and leaves no trail, and the operator asked to
  # reconcile it cannot tell who requested it, when, or why. Recorded outside
  # the transaction, as `record/1` requires. Answers `:ok` so it reads as a
  # step in the caller's `with`.
  defp record_reset_requested(sandbox, ids, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: "sandbox.reset_requested",
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "agent_id" => sandbox.agent_id,
        "provider" => sandbox.provider,
        "conversations" => length(ids),
        "reason" => Keyword.get(opts, :reason, "home_reset")
      }
    })

    :ok
  end

  # Only a confirmed destroy releases capacity. Errors or caller loss leave
  # the committed fence intact for a later explicit reconciliation retry.
  #
  # Since ADR 0058 stage 5c the provider call and the terminal write are the
  # machine owner's, through `Termination._unsafe_destroy_machine/2` and the
  # one destroy protocol (`Fountain.Machines.Destroy`). What that buys the
  # reset is the lease: an owner claims the machine for the length of the
  # operation, so a reconciler retry, an admin retry and an original caller
  # can no longer be inside `Managoat.Sandbox.destroy/1` for one machine at
  # the same time, and the compare-and-set on the lease epoch elects the
  # finalizer where `pending_reset_matches/2`'s status-and-timestamp compare
  # under `update_sandbox/2`'s row lock used to. That predicate was the only
  # thing `update_sandbox_if/3` existed for, so it left with the reset and the
  # function is `do_update_sandbox/2` now.
  #
  # Three protocol options carry the parts of a reset that are *not* a
  # teardown, and the whole of this stage is in them:
  #
  #   * `fence: :held_by_caller` — `reset_sandbox/2` committed
  #     `reset_requested_at` in its own advisory-locked transaction and every
  #     reader honours it, so the machine is already closed. The teardown fence
  #     would additionally stamp `teardown_requested_at`, which tells
  #     `SandboxReaper.sweep_fenced_teardowns/0` to finish the row after 15
  #     minutes — the opposite of a reset, which stays retryable until a
  #     provider confirms.
  #   * `on_provider_error: :refuse` — an unconfirmed delete writes nothing, so
  #     the fence and the tenant's capacity are held exactly as they were.
  #     `sandbox.reset` is the confirmation event and must not be recorded for
  #     a machine that may still be running.
  #   * `provider: :already_gone` — see `confirm_reset_deletion/2`.
  #
  # And two it does not use: `audit_destroy: false`, because the reset's own
  # `sandbox.reset` in `record_reset_completed/3` is the completion event and a
  # `sandbox.destroyed` beside it would describe the same act twice; and no
  # `:notify`, because the reset tells its holders something a reclaim does not
  # — the transcript survives and the next prompt builds a fresh machine — in
  # its own cast and stage event, also in `record_reset_completed/3`.
  defp finish_sandbox_reset(sandbox, opts \\ []) do
    case confirm_reset_deletion(sandbox, Keyword.get(opts, :reprobe, false)) do
      {:ok, provider} -> destroy_reset_machine(sandbox, provider, opts)
      {:error, _uncertain} -> {:error, :sandbox_reset_pending}
    end
  end

  defp destroy_reset_machine(sandbox, provider, opts) do
    # ownership: `sandbox` is always a row this module re-read scoped to its own
    # tenant — `do_reset_sandbox/2`'s `FOR UPDATE` read under the per-sandbox
    # advisory lock, or `retry_pending_sandbox_reset/2`'s
    # `Repo.get_by(id:, user_id:)` — and it carries the reset fence that read
    # established. The protocol re-reads the row under its own lease and
    # refuses one that is not fenced.
    result =
      Termination._unsafe_destroy_machine(sandbox.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        destroy_reason: :reset,
        fence: :held_by_caller,
        provider: provider,
        on_provider_error: :refuse,
        audit_destroy: false,
        terminating_conversation_id: nil
      )

    case result do
      # The protocol answers with an outcome, not a row, and the caller's
      # `with` and every test of it want the retired row.
      {:ok, :destroyed} ->
        {:ok, _unsafe_get_sandbox!(sandbox.id)}

      # `:already_terminal` — somebody else finished this reset while this
      # caller was at the provider. Today's `{:error, :reset_already_completed}`
      # from `pending_reset_matches/2` meant exactly this, and answered
      # `{:ok, :skipped}`, which is what keeps a losing caller from publishing a
      # second completion. `:kept` is unreachable with no terminating
      # conversation.
      {:ok, _outcome} ->
        {:ok, :skipped}

      # The machine's owner is busy with another teardown of the same machine.
      # A retryable condition rather than an unconfirmed deletion, and the one
      # refusal of this path that is not `:sandbox_reset_pending`: the API
      # renders it 503 with a `retry-after`, where `:sandbox_reset_pending` is
      # a 409 that says the fence is standing.
      {:error, :sandbox_unavailable} = busy ->
        busy

      # `:provider_unconfirmed` is the ordinary one and the word this path has
      # always answered with. `:not_fenced` (a caller bug) and anything out of
      # the lease or the database land here too: nothing was written, so the
      # fence is standing and a retry is the way out, which is what the word
      # means. The precise reason is in the log, from `Machines.Destroy`.
      {:error, _reason} ->
        {:error, :sandbox_reset_pending}
    end
  end

  # Whether the provider still has this machine, for a caller that asked to
  # probe before deleting (`reprobe: true`, the admin retry). An operator
  # reconciling a fence wants to know what is actually there: a definitive
  # not-found confirms the retirement on its own, and the protocol is told
  # `provider: :already_gone` so no delete is issued against a name the
  # provider does not recognise. Anything less than definitive — an error, an
  # unreachable provider, a provider with no credentials — keeps the fence.
  #
  # Without `:reprobe` there is no probe, and there does not need to be: the
  # protocol's own destroy treats `{:error, :not_found}` as success, so a
  # machine that is already gone retires on the first call either way.
  defp confirm_reset_deletion(_sandbox, false), do: {:ok, :destroy}

  defp confirm_reset_deletion(%Sandbox{} = sandbox, true) do
    handle = Managoat.Sandbox.build_handle(sandbox_provider_atom(sandbox), sandbox.machine_name)

    if Fountain.SandboxProviders.enabled?(handle.provider) do
      case Managoat.Sandbox.get(handle) do
        {:error, :not_found} -> {:ok, :already_gone}
        {:ok, _} -> {:ok, :destroy}
        error -> error
      end
    else
      {:error, :provider_disabled}
    end
  end

  # What each transcript on a reset home is told. The tail is the same every
  # time — the transcript survives, the next prompt builds a machine — because
  # that is the part a reader needs; the head says whose decision it was.
  @reset_tail "The transcript is kept; the next prompt builds a fresh machine, " <>
                "and the agent starts a new session there."

  defp reset_message("reset_reconciled"),
    do: "The provider confirmed deletion for a pending sandbox reset. " <> @reset_tail

  defp reset_message("environment_changed"),
    do:
      "The agent moved to a different environment, so this machine is no longer its " <>
        @reset_tail

  defp reset_message("environment_deleted"),
    do: "The environment this machine was built for was deleted. " <> @reset_tail

  defp reset_message("vault_deleted"),
    do: "The vault this machine was built for was deleted. " <> @reset_tail

  defp reset_message("teammate_rebound"),
    do:
      "The teammate moved to a different environment or vault, so this machine is no " <>
        "longer its " <> @reset_tail

  defp reset_message(_owner), do: "The sandbox was reset by its owner. " <> @reset_tail

  # A nested transaction does not commit: workers and provider calls must not
  # escape a caller's transaction that can still roll back the accepted rows.
  # Public (door for `Fountain.Conversations.Wake`, #2211, and
  # `Fountain.Conversations.Launch`, #2217): `start_conversation/2`
  # and `attach_conversation/3` below call it locally; `Wake.wake_conversation_for/3`
  # calls it as a remote door since that function moved out of this module.
  @doc false
  def require_provider_commit_boundary do
    if Repo.in_transaction?(), do: {:error, :provider_transaction_open}, else: :ok
  end

  @doc "One of the caller's sandboxes, or nil. A foreign or malformed id reads as nil."
  def get_sandbox(id, user_id) when is_binary(id) and is_binary(user_id) do
    case Ecto.UUID.dump(id) do
      {:ok, _} -> Repo.get_by(Sandbox, id: id, user_id: user_id)
      :error -> nil
    end
  end

  @doc """
  The caller's sandboxes, newest first, each with its conversations (newest
  first). `status: [...]` filters; anything else lists every status, the
  terminated ones included — a machine's history is part of the account.
  """
  def list_sandboxes(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from(s in Sandbox,
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at, desc: s.id]
      )

    query =
      case Keyword.get(opts, :status) do
        [_ | _] = statuses -> where(query, [s], s.status in ^statuses)
        _ -> query
      end

    query
    |> Repo.all()
    |> Repo.preload(conversations: from(c in Conversation, order_by: [desc: c.inserted_at]))
  end

  @doc "`get_sandbox/2` with the conversations preloaded, newest first."
  def get_sandbox_with_conversations(id, user_id) when is_binary(id) and is_binary(user_id) do
    case get_sandbox(id, user_id) do
      nil ->
        nil

      s ->
        Repo.preload(s, conversations: from(c in Conversation, order_by: [desc: c.inserted_at]))
    end
  end

  # A door for `Fountain.Conversations.Reapply` (#2215); not part of the
  # context's public surface.
  @doc false
  def broadcast_sidebar_update(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "sidebar:#{user_id}",
      {:sidebar_update, user_id}
    )
  end

  defp first_turn_query, do: from(t in Turn, where: t.turn_number == 1)

  defp short_id, do: Ecto.UUID.generate() |> binary_part(0, 8)

  # The sandbox name is minted here and stamped on the row; the adapter is
  # handed nothing else (ADR 0018), which is why the runner provider's names
  # carry the runner they live on (ADR 0022) — minting one is a placement
  # decision, made now, and fails plainly when the user has no runner online.
  #
  # A caller-supplied name is a *suffix*, never the whole name (#1632). The
  # name is the machine's identity at the provider, where names are unique per
  # deployment token rather than per tenant, and the Sprites adapter adopts on
  # 409 because it assumes Fountain minted every name it asks for. A verbatim
  # override broke that assumption: two rows in two accounts could name one
  # machine, and that machine holds a tenant's decrypted environment and vault
  # values on disk. Keeping this tenant's prefix on every name puts a chosen
  # name in the caller's own namespace: not reachable adversarially, because a
  # caller cannot pick their own user id, though two accounts whose ids share
  # their first eight characters would share a namespace — #1919 is where a
  # unique index makes that "cannot" rather than "will not". A name that
  # already carries the prefix — one an earlier launch handed back — is taken
  # as it stands.
  # Public (door for `Fountain.Conversations.Wake`, #2211, and
  # `Fountain.Conversations.Launch`, #2217):
  # `create_fresh_sandbox_and_start/4` moved there and calls this remotely;
  # `start_conversation/2` below still calls it locally.
  @doc false
  def mint_machine_name(:runner, user_id, nil), do: Fountain.Runners.mint_sandbox_name(user_id)

  def mint_machine_name(_provider, user_id, nil),
    do: {:ok, machine_name_prefix(user_id) <> short_id()}

  # An empty override is no override, the way an empty sandbox_mode is.
  def mint_machine_name(provider, user_id, ""), do: mint_machine_name(provider, user_id, nil)

  # On the runner provider the name *is* the placement (ADR 0022): the runner
  # id rides in it, because `Managoat.Sandbox` hands an adapter nothing else,
  # and `Runners.parse_sandbox_name/1` reads it back out. An account-scoped
  # name cannot also be a runner name — prefixing `runner-<32 hex>-<8 hex>`
  # produces a name that no longer parses — so there is nothing to honor here
  # and refusing plainly beats minting a sandbox nothing can locate.
  #
  # The override was worse than useless on this provider: `Adapter.rpc/3` reads
  # the runner id out of the name and hands it to `Connection.call/3`, which is
  # `whereis(runner_id)` with no tenant argument, so a verbatim name shaped
  # like another account's runner sandbox routed the launch to their runner.
  # Account-scoped names already break that route (the prefixed name no longer
  # parses), but they break it into a 201 over a row nothing can place; this
  # clause is what makes it a plain refusal instead.
  def mint_machine_name(:runner, _user_id, name) when is_binary(name),
    do: {:error, :sprite_name_not_supported}

  def mint_machine_name(_provider, user_id, name) when is_binary(name) do
    prefix = machine_name_prefix(user_id)
    suffix = String.replace_prefix(name, prefix, "")

    if Regex.match?(@machine_name_suffix, suffix),
      do: {:ok, prefix <> suffix},
      else: {:error, :invalid_sprite_name}
  end

  defp machine_name_prefix(user_id), do: "fountain-#{tenant_prefix(user_id)}-"

  defp tenant_prefix(user_id) when is_binary(user_id), do: binary_part(user_id, 0, 8)

  # A door for `Fountain.Conversations.Reapply` (#2215) and
  # `Fountain.Conversations.Launch` (#2216); not part of the context's public
  # surface.
  @doc false
  def resolve_vault_id(nil, _user_id, _agent), do: {:ok, nil}
  def resolve_vault_id("", _user_id, _agent), do: {:ok, nil}

  def resolve_vault_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_vault_allowed(id, agent) do
      case Fountain.Vaults.get_vault(id, user_id) do
        nil -> {:error, :vault_not_found}
        vault -> {:ok, vault.id}
      end
    end
  end

  # Vault values override the reviewed environment. Use the persisted policy;
  # resolve_vault_id also enforces tenant ownership before attaching a vault.
  defp check_vault_allowed(vault_id, %Agents.Agent{} = agent) do
    if Agents.Agent.vault_allowed?(agent, vault_id), do: :ok, else: {:error, :vault_not_allowed}
  end

  # A per-launch environment override (#783): the conversation is provisioned
  # from this environment instead of the agent's own, and stays pinned to it
  # across wakes. Resolved exactly like the vault — a scoped fetch (a foreign
  # id reads as not found, so it cannot be probed) behind the agent's allowlist.
  # A door for `Fountain.Conversations.Reapply` (#2215) and
  # `Fountain.Conversations.Launch` (#2216); not part of the context's public
  # surface.
  @doc false
  def resolve_environment_id(nil, _user_id, _agent), do: {:ok, nil}
  def resolve_environment_id("", _user_id, _agent), do: {:ok, nil}

  def resolve_environment_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_environment_allowed(id, agent) do
      case Fountain.Environments.get_environment(id, user_id) do
        nil -> {:error, :environment_not_found}
        env -> {:ok, env.id}
      end
    end
  end

  # An override replaces the reviewed environment wholesale, so it is scoped
  # the same way as a vault: use the persisted policy, which also passes the
  # agent's own environment because naming it is not an override. An
  # unrestricted default is deliberate — a caller who can attach a vault can
  # already override every key, so a stricter default here would guard
  # nothing (#783). resolve_environment_id enforces tenant ownership after.
  defp check_environment_allowed(id, %Agents.Agent{} = agent) do
    if Agents.Agent.environment_allowed?(agent, id),
      do: :ok,
      else: {:error, :environment_not_allowed}
  end

  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def resolve_saved_inference(conv, agent) do
    with {:ok, source, _credentials} <-
           InferenceResolution.revalidate(conv, agent,
             environment_id: conv.environment_id || agent.environment_id,
             vault_id: conv.vault_id
           ),
         :ok <- Fountain.PlatformInference.gate_source(source) do
      {:ok, source}
    end
  end

  # A per-launch credential-set override (ADR 0053 decision 3): the
  # conversation provisions on this set instead of the agent's, and stays
  # pinned to it across wakes. Resolved exactly like the environment -- a
  # scoped fetch, so a foreign id reads as not found and cannot be probed,
  # behind the agent's allowlist.
  #
  # Not part of the home identity tuple (ADR 0053 decision 6, and why
  # `_unsafe_find_home/4` is not given one): two conversations differing only
  # in credential set share a machine, because the credential reaches the
  # runtime as process env. InferenceBinding additionally reserves compatible
  # Codex auth state before any shared auth-file write.
  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def resolve_inference_credential_id(nil, _user_id, _agent), do: {:ok, nil}
  def resolve_inference_credential_id("", _user_id, _agent), do: {:ok, nil}

  def resolve_inference_credential_id(id, user_id, agent)
      when is_binary(id) and is_binary(user_id) do
    with :ok <- check_credential_set_allowed(id, agent) do
      case Fountain.InferenceCredentials.get_set(id, user_id) do
        nil -> {:error, :inference_credential_not_found}
        set -> {:ok, set.id}
      end
    end
  end

  def resolve_inference_credential_id(_id, _user_id, _agent),
    do: {:error, :inference_credential_not_found}

  # Same persisted policy as the vault and environment allowlists, and the same
  # deliberately unrestricted default: a caller who can attach a vault can
  # already override `ANTHROPIC_API_KEY` outright, so a stricter default here
  # would guard nothing (#783 made this argument for the environment). The
  # policy also passes the agent's own set, because naming it is not an
  # override. resolve_inference_credential_id enforces tenant ownership after.
  defp check_credential_set_allowed(id, %Agents.Agent{} = agent) do
    if Agents.Agent.credential_set_allowed?(agent, id),
      do: :ok,
      else: {:error, :inference_credential_not_allowed}
  end

  @doc """
  Answer a permission request a running agent is blocked on (#940).

  Tenant-scoped: the conversation is fetched for `user_id` first, so a request
  id from another tenant reads as not found rather than as a permission error.

  **A sprite may not answer its own prompt.** It holds a `FOUNTAIN_TOKEN` and
  could otherwise approve the very tool it just asked for, which would make the
  policy decorative. The loop is closed by name here rather than left to the
  actor vocabulary to imply.

  Audited as a decision about tenant-owned state, per 0013: the tool and the
  verdict, never the tool's input.

  A request that outlived its turn (#1635) is answered through the same door
  and audited the same way. What differs is what the answer does: there is no
  peer left to take it, so the request is resolved on the turn row and a new
  turn is opened carrying it, which wakes a suspended sandbox on the way.
  """
  @spec answer_permission_request(binary(), binary(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def answer_permission_request(conv_id, user_id, request_id, option_id, opts \\ [])
      when is_binary(conv_id) and is_binary(user_id) do
    actor = Keyword.get(opts, :actor, "self")

    case {actor, get_conversation(conv_id, user_id)} do
      {"sprite", _conv} ->
        {:error, :sprite_may_not_answer}

      {_actor, nil} ->
        {:error, :not_found}

      # A conversation nobody can prompt cannot carry an answer back to the
      # agent, so the request is left where it is rather than resolved into
      # nothing.
      {_actor, %Conversation{status: status}} when status not in ["idle", "running"] ->
        {:error, :not_running}

      {_actor, conv} ->
        do_answer_permission(conv, user_id, request_id, option_id, opts)
    end
  end

  # The detached row is looked at first, and deliberately. A turn that ended
  # `waiting` (#1635) left the request on its row while the peer that raised
  # it may still be idle on the sandbox holding the JSON-RPC id: asking the
  # server first would answer a connection whose turn is over and report
  # success, and the new turn that actually carries the answer would never
  # open.
  defp do_answer_permission(conv, user_id, request_id, option_id, opts) do
    # Ownership: established by the tenant-scoped `get_conversation/2` in
    # `answer_permission_request/5` immediately above this call.
    case _unsafe_waiting_turn(conv.id, request_id) do
      nil -> answer_held_permission(conv.id, user_id, request_id, option_id, opts)
      turn -> answer_detached_permission(conv, turn, user_id, option_id, opts)
    end
  end

  defp answer_held_permission(conv_id, user_id, request_id, option_id, opts) do
    case ConversationServer.answer_permission(conv_id, request_id, option_id) do
      :ok ->
        record_permission_answered(conv_id, user_id, request_id, option_id, opts)

      {:error, _} = err ->
        err
    end
  end

  # A request nobody is holding open any more: resolve the row, then open the
  # turn that tells the agent.
  #
  # Every gate the wake path would apply is applied **first**, before the row
  # is touched. Resolving and then failing to deliver loses the answer with
  # nothing to retry from, and hands the caller a 409 that says somebody else
  # answered — which is a lie about what happened.
  defp answer_detached_permission(conv, turn, user_id, option_id, opts) do
    request = turn.pending_permission
    request_id = request["request_id"]

    if DetachedRequest.offered?(request, option_id) do
      with :ok <- _unsafe_resume_gate(conv),
           :ok <- _unsafe_resolve_detached_request(turn, "answered", option_id),
           :ok <-
             record_permission_answered(
               turn.conversation_id,
               user_id,
               request_id,
               option_id,
               opts
             ) do
        resume_after_request(turn, request, "answered", option_id, opts)
      end
    else
      {:error, :unknown_option}
    end
  end

  @doc """
  Whether a resume turn can be opened on this conversation right now (#1635).

  The gates the wake will run, run before the request row is resolved. The
  three answers differ in what a caller should do about them:

  * `:ok` — go ahead.
  * `{:error, :busy}` — a turn is running, so the resume turn cannot queue
    behind it. Retry when the conversation is idle; the sweep does, a minute
    later.
  * `{:error, :gone}` — the conversation is over, so no turn will ever carry
    the answer.

  Anything else is the account's own refusal (suspended, out of credit), and
  is retryable once the account is not.

  WARNING: not scoped by owner. The answer door establishes ownership first;
  the sweep is a system sweep.
  """
  @spec _unsafe_resume_gate(Conversation.t() | binary()) :: :ok | {:error, term()}
  def _unsafe_resume_gate(conv_id) when is_binary(conv_id) do
    case _unsafe_get_conversation(conv_id) do
      nil -> {:error, :gone}
      conv -> _unsafe_resume_gate(conv)
    end
  end

  def _unsafe_resume_gate(%Conversation{} = conv) do
    cond do
      conv.status in ["terminated", "failed"] ->
        {:error, :gone}

      conv.status != "idle" ->
        {:error, :busy}

      true ->
        with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id) do
          Fountain.Billing.check_spend(conv.user_id)
        end
    end
  end

  defp record_permission_answered(conv_id, user_id, request_id, option_id, opts) do
    Audit.record(%{
      user_id: user_id,
      action: "conversation.permission_answered",
      resource_type: "conversation",
      resource_id: conv_id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"request_id" => request_id, "option_id" => option_id}
    })

    :ok
  end

  @doc """
  The turn a detached request is waiting on, or nil (#1635).

  WARNING: not scoped by owner. Call it after a tenant-scoped fetch of the
  conversation, which is what `answer_permission_request/5` does.
  """
  @spec _unsafe_waiting_turn(binary(), String.t()) :: Turn.t() | nil
  def _unsafe_waiting_turn(conv_id, request_id) do
    Turn
    |> where([t], t.conversation_id == ^conv_id and t.waiting == true)
    |> where([t], fragment("?->>'request_id' = ?", t.pending_permission, ^request_id))
    |> Repo.one()
  end

  @doc """
  Every request this conversation is waiting on, oldest turn first (#1635).

  WARNING: not scoped by owner. Call it after a tenant-scoped fetch, which is
  what `ConversationController.show/2` does.
  """
  @spec _unsafe_list_pending_requests(binary()) :: [map()]
  def _unsafe_list_pending_requests(conv_id) do
    Turn
    |> where([t], t.conversation_id == ^conv_id and t.waiting == true)
    |> where([t], not is_nil(t.pending_permission))
    |> order_by([t], asc: t.turn_number)
    |> Repo.all()
    |> Enum.map(&DetachedRequest.to_json(&1.pending_permission, &1))
  end

  @doc """
  Take a detached request off its turn, once (#1635).

  First answer wins, and here that is enforced by the update itself rather
  than by a process holding the request: the `where` names the request id the
  caller read, so a second answer, the sweep and a client racing the sweep all
  find nothing to update and get `{:error, :no_pending_permission}`.

  The `request`/`done` stage event is published by whoever won, exactly as the
  in-turn path publishes it.

  WARNING: not scoped by owner. Both callers establish ownership first — the
  answer door by fetching the conversation for the user, the sweep by being a
  system sweep.
  """
  @spec _unsafe_resolve_detached_request(Turn.t(), String.t(), String.t() | nil) ::
          :ok | {:error, :no_pending_permission}
  def _unsafe_resolve_detached_request(%Turn{} = turn, outcome, option_id) do
    request_id = turn.pending_permission["request_id"]

    {count, _} =
      Turn
      |> where([t], t.id == ^turn.id and t.waiting == true)
      |> where([t], fragment("?->>'request_id' = ?", t.pending_permission, ^request_id))
      |> Repo.update_all(set: [waiting: false, pending_permission: nil, permission_deadline: nil])

    if count == 1 do
      publish_stage(turn.conversation_id, "request", "done", %{
        request_id: request_id,
        outcome: outcome,
        option_id: option_id,
        detached: true
      })

      :ok
    else
      {:error, :no_pending_permission}
    end
  end

  @doc """
  Deny a detached request whose deadline has passed, and tell the agent
  (#1635).

  The denial picks from the options the agent itself offered, never an id it
  did not send. Recorded as `conversation.permission_denied` with the sweep as
  the actor, because no human was at the keyboard and saying otherwise would
  be a lie about who decided.
  """
  @spec _unsafe_expire_detached_request(Turn.t(), keyword()) ::
          :ok | {:error, term()}
  def _unsafe_expire_detached_request(%Turn{} = turn, opts \\ []) do
    request = turn.pending_permission
    option_id = DetachedRequest.deny_option_id(request)
    actor = Keyword.get(opts, :actor, "system:detached_request_sweeper")

    # The gate first, for the same reason the answer door applies it first: a
    # request resolved into a prompt nobody can deliver is gone, the agent is
    # never told, and there is no second copy to retry from. The deadline has
    # passed either way, so leaving the row is the safe half of the trade —
    # the sweep is back in a minute.
    #
    # A conversation that is over is the exception: no turn will ever carry
    # the denial, so the request is resolved and the card stops waiting.
    case _unsafe_resume_gate(turn.conversation_id) do
      :ok ->
        with :ok <- _unsafe_resolve_detached_request(turn, "timeout", option_id) do
          record_permission_denied(turn.conversation_id, request["tool"], "timeout", actor: actor)
          resume_after_request(turn, request, "timeout", option_id, actor: actor)
        end

      {:error, :gone} ->
        with :ok <- _unsafe_resolve_detached_request(turn, "timeout", option_id) do
          record_permission_denied(turn.conversation_id, request["tool"], "timeout", actor: actor)
          :ok
        end

      {:error, _} = err ->
        err
    end
  end

  # The resolution reaches the agent as a new turn, because the peer that
  # raised the request is gone and its JSON-RPC id with it. `send_prompt/4`
  # wakes a suspended sandbox on the way, which is the whole point of letting
  # the request outlive the turn.
  defp resume_after_request(turn, request, outcome, option_id, opts) do
    case ConversationServer.send_prompt(
           turn.conversation_id,
           DetachedRequest.resume_prompt(request, outcome, option_id),
           [],
           opts
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        # The gates above passed and the row is already resolved, so this is a
        # race rather than a refusal: something took the conversation between
        # the two. Its own error would tell the caller to retry an answer that
        # no longer exists, so it becomes one that says what actually
        # happened.
        Logger.warning(
          "conv #{turn.conversation_id}: resolved detached request " <>
            "#{request["request_id"]} but could not open the turn that carries " <>
            "the answer: #{inspect(reason)}"
        )

        {:error, :answer_not_delivered}
    end
  end

  @doc """
  Record that the permission policy withheld a tool from a running agent.

  Called by the `ConversationServer` when its peer reports a refusal (#939).
  The actor defaults to `sprite`: the agent asked, the policy answered, and no
  human was involved — attributing it to the person who happened to write the
  policy would be a lie about who was at the keyboard. A detached request that
  ran out of time (#1635) passes the sweep instead, for the same reason.

  Only refusals are recorded. A turn makes dozens of tool calls and a row per
  allow would make the trail a second copy of the transcript, which 0013
  forbids for exactly this reason. The tool's *input* is never recorded, only
  its name and the verdict.
  """
  @spec record_permission_denied(binary(), String.t() | nil, String.t(), keyword()) :: :ok
  def record_permission_denied(conversation_id, tool, verdict, opts \\ [])
      when is_binary(conversation_id) do
    case _unsafe_get_conversation(conversation_id) do
      nil ->
        :ok

      conv ->
        Audit.record(%{
          user_id: conv.user_id,
          action: "conversation.permission_denied",
          resource_type: "conversation",
          resource_id: conv.id,
          actor: Keyword.get(opts, :actor, "sprite"),
          metadata: %{"tool" => tool, "verdict" => verdict}
        })

        :ok
    end
  end

  @doc """
  Check current ceilings before an already-owned conversation starts another turn.

  Reads the saved allowance from `execution_allowances` (#1790) rather than a
  column on the parent: that row carries a revision, so a launch and a resume
  cannot silently overwrite each other's policy.
  """
  def _unsafe_execution_limits_gate(%Conversation{} = conv) do
    # ownership: the caller fetched this conversation for its actor or for an
    # authorized API operation.
    with :ok <- _unsafe_check_saved_execution_allowance(conv.id),
         do: ExecutionGuard._unsafe_admission_gate(conv.id)
  end

  # A per-launch permission override (#939). Unlike the vault and environment
  # overrides, this one needs no allowlist on the agent: `check_narrows/2`
  # refuses anything looser than the agent's own policy, so a launch cannot
  # reach a permission the agent did not already grant. There is nothing to
  # allow-list because there is nothing to escalate to.
  #
  # Rejected loudly rather than clamped. `Permissions.effective/2` clamps
  # anyway — that is the invariant the peer relies on — but a caller who asked
  # to loosen a policy and silently got a tighter one would have no way to
  # tell, and the difference matters when the ask was a mistake.
  # A door for `Fountain.Conversations.Reapply` (#2215); not part of the
  # context's public surface.
  @doc false
  def resolve_permission_policy(nil, _agent), do: {:ok, nil}
  def resolve_permission_policy(policy, _agent) when policy == %{}, do: {:ok, nil}

  def resolve_permission_policy(policy, agent) when is_map(policy) do
    # The reserved keys are not tools, so the library never sees them and
    # narrows them itself (#1635, `Fountain.PermissionPolicy`).
    verdicts = PermissionPolicy.verdicts(policy)

    with :ok <- validate_policy_shape(policy),
         :ok <- check_runtime_asks(verdicts, agent),
         :ok <-
           Managoat.ACP.Permissions.check_narrows(
             PermissionPolicy.verdicts(agent.permission_policy),
             verdicts
           ),
         :ok <-
           PermissionPolicy.check_narrows(
             agent.permission_policy,
             policy,
             div(Lifecycle.ask_timeout_ms(), 1000)
           ) do
      {:ok, policy}
    end
  end

  def resolve_permission_policy(_policy, _agent), do: {:error, :permission_policy_invalid}

  # A launch cannot be protected by a policy the runtime never consults. Refused
  # rather than accepted-and-ignored — see `ACP.asks_permission?/1`, measured.
  defp check_runtime_asks(policy, agent) do
    if not Managoat.ACP.Permissions.needs_enforcement?(policy) or
         Fountain.RuntimeDispatch.asks_permission?(agent.runtime) do
      :ok
    else
      {:error, {:permission_policy_unenforceable, agent.runtime}}
    end
  end

  defp validate_policy_shape(policy) do
    with :ok <- validate_reserved_keys(policy) do
      policy
      |> PermissionPolicy.verdicts()
      |> Enum.find_value(:ok, fn {tool, verdict} ->
        cond do
          not is_binary(tool) or tool == "" ->
            {:error, :permission_policy_invalid}

          verdict not in Managoat.ACP.Permissions.verdicts() ->
            {:error, :permission_policy_invalid}

          not Managoat.ACP.Permissions.buildable?(verdict) ->
            {:error, {:permission_policy_unbuilt, verdict}}

          true ->
            nil
        end
      end)
    end
  end

  defp validate_reserved_keys(policy) do
    case PermissionPolicy.reserved_errors(policy) do
      [] -> :ok
      _errors -> {:error, :permission_policy_invalid}
    end
  end

  def sandbox_provider_atom(%{provider: provider}) when is_binary(provider),
    do: String.to_existing_atom(provider)

  def sandbox_provider_atom(_sandbox), do: :sprites

  # Placement for a NEW sandbox: the agent's override, else the instance
  # default. Only an override is gated on enabledness — the default keeps its
  # lazy credential check (a credential-less boot fails at provision time
  # with the missing variable named, exactly as before), while an agent
  # pinned to a provider whose credentials were since removed fails here
  # with an error the API/UI can explain.
  # A door for `Fountain.Conversations.Reapply` (#2215); not part of the
  # context's public surface.
  @doc false
  def resolve_sandbox_provider(%Agents.Agent{sandbox_provider: nil}),
    do: {:ok, Fountain.SandboxProviders.default_provider()}

  def resolve_sandbox_provider(%Agents.Agent{sandbox_provider: value}) do
    provider = String.to_existing_atom(value)

    if Fountain.SandboxProviders.enabled?(provider) do
      {:ok, provider}
    else
      {:error, {:sandbox_provider_disabled, provider}}
    end
  end
end
