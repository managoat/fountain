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

  alias Fountain.Conversations.Reapply
  alias Fountain.Conversations.{ExecutionAllowance, ExecutionLimits}
  alias Fountain.Conversations.Lifecycle
  alias Fountain.PermissionPolicy
  alias Fountain.Repo

  # Advisory-lock namespace for per-sandbox machine operations. Distinct from
  # Quotas' per-user reservation (4315): this one is taken inside a turn
  # start, and the two must never be mistaken for one another.
  @sandbox_lock_namespace 4316

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
  Whether a conversation other than `conv_id` still holds `sandbox_id` — one
  that is not `terminated`/`failed`. A sandbox normally has one conversation;
  it gets a second when a teammate starts a fresh conversation on the same
  computer (`ConversationServer.release_conversation/2`, `Fountain.Team`),
  and from then on the retired thread's lifecycle must not reach the disk
  its successor is running on. `_unsafe_`: callers have established
  ownership of `conv_id` already (a GenServer, or a scoped fetch before it).
  """
  def _unsafe_sandbox_held_by_other?(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.exists?(
      from(c in Conversation,
        where:
          c.sandbox_id == ^sandbox_id and c.id != ^conv_id and
            c.status not in ["terminated", "failed"]
      )
    )
  end

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

  @doc """
  Support teardown of any tenant's sandbox, from the admin panel.

  A conversation with a live `ConversationServer` is terminated through the
  server, which destroys the sprite and ends the conversation — that is what
  stopping a runaway agent means. A sandbox with no live server (including a
  `suspended` one) just has its row marked terminated: the conversation stays
  resumable (next prompt gets a fresh sandbox, with the agent's memory lost —
  decisions/0017) and the reaper destroys the sprite on its next pass, the
  same split `SandboxReaper.sweep_abandoned_sandboxes/0` uses.
  """
  def _unsafe_reap_sandbox(sandbox_id) do
    alias Fountain.Conversations.ConversationServer

    case _unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :not_found}

      %Sandbox{status: s} when s in ["terminated", "failed"] ->
        {:ok, :already_terminal}

      sandbox ->
        sandbox = Repo.preload(sandbox, :conversations)
        live = Enum.filter(sandbox.conversations, &ConversationServer.whereis(&1.id))

        if live == [] do
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          {:ok, _} = update_sandbox(sandbox, %{status: "terminated", terminated_at: now})
          {:ok, :released}
        else
          # A reclaimed sandbox took the tenant's conversations down with it,
          # which is worth a row each — this is the one termination they did
          # not ask for. #551 covers the reaper that calls this.
          Enum.each(
            live,
            &ConversationServer.terminate_conversation(&1.id, actor: "system:sandbox_reaper")
          )

          {:ok, :terminated}
        end
    end
  end

  @doc """
  Reap every active sandbox belonging to `user_id` — the suspension path
  (#287). `_unsafe_` per the tenant contract: unscoped, and legitimate callers
  are admin-driven (`Accounts.suspend_user/1` behind `require_admin`).

  Best-effort by design: each sandbox reaps independently and a failure moves
  on — suspension must not be blocked by one wedged sprite; `SandboxReaper`
  sweeps stragglers. Returns the number of sandboxes reaped.
  """
  def _unsafe_reap_all_for_user(user_id) when is_binary(user_id) do
    # Deliberately NOT Quotas.active_statuses(): `suspended` is excluded from
    # the concurrency cap (a parked sprite is not compute) but its sprite is
    # very much alive at sprites.dev, and a suspended tenant must not keep it.
    from(s in Sandbox,
      where: s.user_id == ^user_id and s.status in ~w(pending starting ready suspended),
      select: s.id
    )
    |> Repo.all()
    |> Enum.count(fn id -> match?({:ok, _}, _unsafe_reap_sandbox(id)) end)
  end

  def create_sandbox(attrs) do
    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a sandbox, emitting usage events on billable transitions.

  Every sandbox status change in the system goes through here — fresh
  provisioning, the wake path, and the terminate-when-the-server-is-already-dead
  path in `ConversationServer.terminate_conversation/2`. Metering at this choke point means a
  new caller cannot forget to record usage, which is how `Billing.emit/5` ended
  up with no call sites at all despite being documented, schema'd and tested.

  The persisted previous status decides the transition. Terminal rows reject
  attempts to become active again, including callbacks holding an older struct.
  """
  # The two statuses a sandbox stops at. `update_sandbox/2` reads this before
  # `prevent_sandbox_revival/1` does, so it is declared here rather than beside it.
  @billable_terminal ~w(terminated failed)

  def update_sandbox(%Sandbox{} = sandbox, attrs) do
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
  defp stamp_terminated_at(changeset) do
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
  defp record_sandbox_usage(was, %Sandbox{status: "ready"} = sandbox)
       when was in ["pending", "starting"] do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_provisioned",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name, "provider" => sandbox.provider}
    )
  end

  # `suspended → ready`: the wake side of a park/wake cycle (0017). No
  # sandbox_provisioned here — the provision was already recorded before the
  # sandbox parked (see above) — but the parked interval needs a start and an
  # end of its own so the duration roll-up can subtract it from
  # sandbox_terminated's duration_ms instead of billing parked time (#665).
  defp record_sandbox_usage("suspended", %Sandbox{status: "ready"} = sandbox) do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_resumed",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name, "provider" => sandbox.provider}
    )
  end

  # `ready → suspended`: the sandbox is parked, not destroyed, and stops
  # billing compute from here (0017). Paired with sandbox_resumed (or, for a
  # sandbox that never wakes again, with sandbox_terminated) so the duration
  # roll-up can tell parked time apart from run time (#665).
  defp record_sandbox_usage(was, %Sandbox{status: "suspended"} = sandbox)
       when was not in @billable_terminal do
    Fountain.Billing.record_usage(
      sandbox.user_id,
      "sandbox_suspended",
      sandbox.id,
      "sandbox",
      %{"sprite_name" => sandbox.sprite_name, "provider" => sandbox.provider}
    )
  end

  defp record_sandbox_usage(was, %Sandbox{status: status} = sandbox)
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
          "sprite_name" => sandbox.sprite_name,
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

  defp record_sandbox_usage(_was, _sandbox), do: :ok

  defp sandbox_duration_ms(%Sandbox{inserted_at: nil}), do: 0

  defp sandbox_duration_ms(%Sandbox{inserted_at: started} = sandbox) do
    ended = sandbox.terminated_at || DateTime.utc_now()
    ended |> DateTime.diff(started, :millisecond) |> max(0)
  end

  # ── conversations ─────────────────────────────────────────────────────────────────────

  @doc """
  Conversations the operator might still want to interact with: anything
  not in a terminal state. Ordered with active sessions on top
  (`running` > `idle`) and most-recent first within a status bucket.
  Used for the left-nav "active conversations" list.
  """
  def _unsafe_list_active_conversations do
    Repo.all(
      from c in Conversation,
        where: c.status not in ["terminated", "failed"],
        order_by: [
          asc:
            fragment(
              "CASE ? WHEN 'running' THEN 0 WHEN 'idle' THEN 1 ELSE 2 END",
              c.status
            ),
          desc: c.inserted_at,
          desc: c.id
        ],
        preload: [:agent, turns: ^first_turn_query()]
    )
  end

  @doc """
  List conversations for `user_id`, ordered by most recently active.

  Populates the `turn_count` virtual field on each conversation by LEFT
  JOINing a subquery that counts turns per conversation. This avoids an
  N+1 and keeps the result a plain list of `%Conversation{}` structs.

  Only `kind: "output"` log events count toward `last_active_at` —
  `kind: "stage"` events (reattach, sandbox lifecycle) are excluded so
  that reconnects don't artificially bump a conversation to the top.
  """
  def list_conversations_by_activity(user_id) when is_binary(user_id) do
    # Lateral per conversation for the same reason as `annotated_query/1`:
    # the grouped shape read every turn and every output log event in the
    # deployment to rank one tenant's list.
    Repo.all(
      from c in Conversation,
        as: :conv,
        where: c.user_id == ^user_id and c.status != "terminated",
        left_lateral_join: tc in subquery(turn_count_of_conv()),
        on: true,
        left_lateral_join: lt in subquery(last_turn_at_of_conv()),
        on: true,
        left_lateral_join: ll in subquery(last_output_at_of_conv()),
        on: true,
        order_by: [
          desc:
            fragment(
              "GREATEST(COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), ? AT TIME ZONE 'UTC')",
              ll.last_at,
              c.inserted_at,
              lt.last_at,
              c.inserted_at,
              c.inserted_at
            )
        ],
        select: %{
          c
          | turn_count: fragment("COALESCE(?, 0)", tc.count),
            last_active_at:
              fragment(
                "GREATEST(COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC'), ? AT TIME ZONE 'UTC')",
                ll.last_at,
                c.inserted_at,
                lt.last_at,
                c.inserted_at,
                c.inserted_at
              )
        }
    )
    |> Repo.preload([:agent, :agent_version, turns: first_turn_query()])
  end

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

  defp last_turn_at_of_conv do
    from t in Turn,
      where: t.conversation_id == parent_as(:conv).id,
      select: %{last_at: max(t.inserted_at)}
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
  defp insert_conversation_row(attrs) do
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
  defp after_conversation_created(%Conversation{} = conv) do
    Fountain.Activation.conversation_created(conv)
  end

  @doc """
  Register the caller-defined tools of the bridge (#1202) on a conversation
  the caller already owns: the normalised list `Fountain.CallerTools`
  produced, last write wins. An unchanged list writes and records nothing —
  a framework loop re-sends the same list on every request.

  Ownership is the caller's job: `conv` must have come from a tenant-scoped
  fetch. Audited as `conversation.caller_tools_set` with the count and the
  names, never the schemas.
  """
  @spec set_caller_tools(Conversation.t(), [map()], keyword()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def set_caller_tools(%Conversation{} = conv, tools, opts \\ []) when is_list(tools) do
    if conv.caller_tools == tools do
      {:ok, conv}
    else
      conv
      |> Conversation.changeset(%{caller_tools: tools})
      |> Repo.update()
      |> tap(fn
        {:ok, updated} ->
          Audit.record(%{
            user_id: updated.user_id,
            action: "conversation.caller_tools_set",
            resource_type: "conversation",
            resource_id: updated.id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: %{
              "tool_count" => length(tools),
              "tool_names" => Enum.map(tools, & &1["name"])
            }
          })

        _ ->
          :ok
      end)
    end
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
  def _unsafe_merge_labels(conv, labels, opts \\ [])

  def _unsafe_merge_labels(%Conversation{} = conv, labels, opts) when is_map(labels) do
    current = conv.labels || %{}
    merged = Labels.merge(current, labels)

    cond do
      merged == current -> {:ok, conv}
      true -> write_labels(conv, current, labels, merged, opts)
    end
  end

  # Anything that is not a map is a validation failure with the same shape a
  # broken limit produces, so a caller reads one answer whichever door it
  # came through.
  def _unsafe_merge_labels(%Conversation{} = conv, labels, _opts) do
    {:error, label_refusal(conv, Labels.check(labels))}
  end

  defp write_labels(conv, current, labels, merged, opts) do
    case Labels.check_merge(current, labels) do
      :ok ->
        {written, removed} = Labels.changed_keys(current, labels)

        conv
        |> Conversation.changeset(%{labels: merged})
        |> Repo.update()
        |> tap(fn
          {:ok, updated} -> record_labels_set(updated, written, removed, merged, opts)
          _ -> :ok
        end)

      refusal ->
        {:error, label_refusal(conv, refusal)}
    end
  end

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

  @doc """
  Finish an actor's termination only while the conversation is still bound to
  its sandbox. The binding check and status write are one database statement,
  so a reassignment during provider cleanup cannot terminate the new binding.

  The actor owns both IDs. This is internal lifecycle bookkeeping; the public
  `ConversationServer.terminate_conversation/2` records the action's audit once
  after a successful reply. A missing or moved conversation returns a refusal.
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
        broadcast_sidebar_update(conv.user_id)
        {:ok, conv}

      {0, _} ->
        {:error, :sandbox_unavailable}
    end
  end

  @doc """
  Re-resolve the Agent, Environment and Vault for an existing conversation,
  on the machine it is already running (#1565).

  `conv` must come from `get_conversation/2`; the lookups below are
  tenant-scoped to that owner. An omitted field keeps its current selection,
  and an explicit nil clears the Environment override or the Vault. An empty
  map is therefore a refresh of what is already selected.

  The sandbox is kept. Environment variables, the system prompt, skills and
  MCP servers are what a later link of this stack rewrites under it;
  everything the agent has on disk survives either way.

  A selection that would need the disk built again is refused as
  `{:error, {:rebuild_required, field}}` rather than silently applied or
  silently ignored. `Fountain.Conversations.Reapply` owns that rule and says
  why for each field.

  ## What `{:ok, conv}` promises

  That the selection is committed, and that no turn can open against the
  previous one: `configuration_revision` moved, and turn admission compares it
  with the revision the live server loaded.

  It does not promise the running machine has already been reconfigured. A
  server is told after the commit, and it can be mid-provision or gone by then.
  Neither loses the change — the next wake builds from the row — so neither is
  a failure of this call, and reporting one would hand the caller an error for
  a selection that is already committed. The `configuration` stage event says
  which of the two happened: `done` when a machine is configured now, `failed`
  when it is selected and the machine has yet to catch up.
  """
  @spec reapply_conversation(Conversation.t(), map(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def reapply_conversation(%Conversation{} = conv, attrs \\ %{}, opts \\ [])
      when is_map(attrs) do
    with {:ok, {previous, updated}} <-
           with_sandbox_lock(conv.sandbox_id, fn ->
             # Ownership was established by the caller. Re-read under the lock
             # so concurrent reapplications preserve each other's omitted
             # fields rather than each writing from a stale copy.
             current =
               Repo.one!(from c in Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE")

             if current.sandbox_id == conv.sandbox_id,
               do: do_reapply_conversation(current, attrs),
               else: {:error, :provisioning}
           end) do
      metadata = reapply_metadata(previous, updated)

      # Outside the transaction: a failed audit insert would abort the
      # enclosing one and take the reapply with it.
      Audit.record(%{
        user_id: updated.user_id,
        action: "conversation.configuration_reapplied",
        resource_type: "conversation",
        resource_id: updated.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: metadata
      })

      broadcast_sidebar_update(updated.user_id)
      announce_reapply(updated, metadata)
      {:ok, updated}
    end
  end

  # The selection is committed by the time this runs, so it is not in doubt and
  # the caller is not told otherwise. What is still in doubt is whether a
  # machine has read it, and only `{:ok, :reloaded}` says one has. Everything
  # else — no server, no machine, a server that refused — leaves the selection
  # standing with nothing rewritten anywhere, which is the `failed` sentence
  # rather than a `done` that would claim a machine is configured.
  #
  # Best-effort as a whole: this runs after the commit, so neither the call nor
  # `publish_stage/4`'s own insert may take a reapply that already happened.
  defp announce_reapply(conv, metadata) do
    try do
      common = %{
        event: "reapplied",
        previous: metadata["previous"],
        current: metadata["current"],
        changed_fields: metadata["changed_fields"]
      }

      case Fountain.Conversations.ConversationServer.refresh_configuration(
             conv.id,
             conv.configuration_revision
           ) do
        {:ok, :reloaded} ->
          publish_stage(
            conv.id,
            "configuration",
            "done",
            Map.put(
              common,
              :message,
              "The configuration was reapplied on this machine. The transcript and the " <>
                "files on disk are kept; the next prompt starts a new runtime session."
            )
          )

        # Total on purpose. This runs after the commit, so an unexpected shape
        # here must become an event rather than a CaseClauseError that 500s a
        # reapply which already happened.
        other ->
          publish_stage(
            conv.id,
            "configuration",
            "failed",
            common
            |> Map.put(:reason, refresh_reason(other))
            |> Map.put(
              :message,
              "The configuration is selected. No machine has read it yet; it is " <>
                "applied when this conversation next wakes, and no turn can run " <>
                "against the previous selection in the meantime."
            )
          )
      end
    rescue
      error ->
        Logger.error(
          "conv #{conv.id}: announcing the reapplied configuration raised: " <>
            Exception.format(:error, error, __STACKTRACE__)
        )
    end

    :ok
  end

  defp refresh_reason({:ok, reason}), do: refresh_reason(reason)
  defp refresh_reason({:error, reason}), do: refresh_reason(reason)
  defp refresh_reason(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp refresh_reason(other), do: inspect(other)

  defp do_reapply_conversation(conv, attrs) do
    agent_id = reapply_value(attrs, "agent_id", conv.agent_id)
    vault_selection = reapply_value(attrs, "vault_id", conv.vault_id)
    environment_selection = reapply_value(attrs, "environment_id", conv.environment_id)

    with :ok <- assert_reapplicable(conv),
         {:ok, agent_id} <- reapply_agent_id(agent_id),
         %Fountain.Agents.Agent{} = agent <-
           Fountain.Agents.get_agent(agent_id, conv.user_id) || {:error, :not_found},
         {:ok, _runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         {:ok, _provider} <- resolve_sandbox_provider(agent),
         {:ok, vault_id} <- resolve_vault_id(vault_selection, conv.user_id, agent),
         {:ok, environment_id} <-
           resolve_environment_id(environment_selection, conv.user_id, agent),
         {:ok, _permission_policy} <- resolve_permission_policy(conv.permission_policy, agent),
         :ok <- assert_applicable_in_place(conv, agent, environment_id, vault_id),
         {:ok, updated} <-
           write_reapplied_configuration(conv,
             agent_id: agent.id,
             # Ownership: `agent` was fetched above by both id and conv.user_id.
             agent_version_id: Fountain.Agents._unsafe_current_version_id(agent.id),
             vault_id: vault_id,
             environment_id: environment_id,
             runtime: agent.runtime,
             configuration_revision: conv.configuration_revision + 1
           ),
         :ok <- Reapply.update_identity(conv, agent, environment_id, vault_id) do
      {:ok, {conv, updated}}
    end
  end

  # An omitted key keeps what the row already says; a key present with an
  # explicit nil clears it. Both spellings are accepted because the API hands
  # string keys through and the context's own callers use atoms.
  defp reapply_value(attrs, key, current) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, atom_key) -> Map.get(attrs, atom_key)
      true -> current
    end
  end

  # `conversations.agent_id` is `nilify_all`, so deleting an agent leaves the
  # conversation naming nothing and an omitted `agent_id` inherits that nil.
  # Ecto refuses to compare nil in a query, so the lookup would raise rather
  # than answer; refuse the way a wake does instead. An id that was supplied
  # and does not resolve is a different answer, and the lookup still gives it.
  defp reapply_agent_id(id) when is_binary(id), do: {:ok, id}
  defp reapply_agent_id(nil), do: {:error, :no_agent}
  defp reapply_agent_id(_other), do: {:error, :not_found}

  # Ownership: `conv` reached here from a tenant-scoped fetch, the sandbox is
  # its own, and the environments are looked up scoped to the same owner.
  defp assert_applicable_in_place(%Conversation{sandbox_id: nil}, _agent, _env_id, _vault_id),
    do: :ok

  defp assert_applicable_in_place(%Conversation{} = conv, agent, environment_id, vault_id) do
    sandbox = _unsafe_get_sandbox(conv.sandbox_id)
    target_environment_id = environment_id || agent.environment_id
    target_identity = {agent.id, target_environment_id, vault_id}

    with :ok <- assert_not_shared(sandbox, conv, target_identity) do
      Reapply.check(sandbox,
        current_runtime: conv.runtime,
        target_runtime: agent.runtime,
        target_environment: environment_for(target_environment_id, conv.user_id),
        built_with: sandbox && environment_for(sandbox.environment_id, conv.user_id)
      )
    end
  end

  # Skills, instructions and MCP config live at per-machine paths, so
  # reconfiguring a shared machine reconfigures it for its cotenants too.
  # `check_attachable/4` pins every conversation on a machine to one identity,
  # so a selection that still matches theirs is the refresh they would want
  # anyway. Anything else is refused rather than imposed on them.
  defp assert_not_shared(nil, _conv, _target), do: :ok

  defp assert_not_shared(%Sandbox{} = sandbox, conv, target) do
    if _unsafe_sandbox_held_by_other?(sandbox.id, conv.id) and
         {sandbox.agent_id, sandbox.environment_id, sandbox.vault_id} != target do
      {:error, {:rebuild_required, :shared_sandbox}}
    else
      :ok
    end
  end

  defp environment_for(nil, _user_id), do: nil
  defp environment_for(id, user_id), do: Fountain.Environments.get_environment(id, user_id)

  # A prompt that arrives between the checks above and this write would wake
  # the conversation and start a turn on the configuration being replaced.
  # One guarded statement: the row moves only while no turn runs, and a caller
  # that lost the race is told it is busy rather than silently overwritten.
  defp write_reapplied_configuration(%Conversation{} = conv, fields) do
    running_turn =
      from(t in Turn,
        where: t.conversation_id == parent_as(:conv).id and t.status == "running",
        select: 1
      )

    fields = Keyword.put(fields, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

    {count, _} =
      from(c in Conversation, as: :conv, where: c.id == ^conv.id and not exists(running_turn))
      |> Repo.update_all(set: fields)

    if count == 1,
      do: {:ok, _unsafe_get_conversation!(conv.id)},
      else: {:error, :conversation_busy}
  end

  defp assert_reapplicable(%Conversation{status: "idle", id: id}),
    do: assert_no_running_turn(id)

  defp assert_reapplicable(%Conversation{status: "running"}),
    do: {:error, :conversation_busy}

  # A conversation created without a prompt never leaves `pending`: provision
  # success flips the *sandbox* row, and only a turn ending writes `idle`. So
  # refusing every `pending` row would put "I picked the wrong agent before I
  # sent anything" permanently out of reach, behind a Retry-After that never
  # cleared. A provision genuinely in flight is still a retry.
  defp assert_reapplicable(%Conversation{status: "pending"} = conv) do
    if reapply_provision_in_flight?(conv),
      do: {:error, :provisioning},
      else: assert_no_running_turn(conv.id)
  end

  defp assert_reapplicable(%Conversation{status: status}) when status in ~w(failed terminated),
    do: {:error, :gone}

  # Ownership: `conv` reached here from a tenant-scoped fetch, and the row
  # read below is its own machine.
  defp reapply_provision_in_flight?(%Conversation{sandbox_id: nil}), do: false

  defp reapply_provision_in_flight?(%Conversation{sandbox_id: sandbox_id}) do
    case _unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: status} when status in ["pending", "starting"] -> true
      _ -> false
    end
  end

  defp assert_no_running_turn(conversation_id) do
    if Repo.exists?(
         from t in Turn,
           where: t.conversation_id == ^conversation_id and t.status == "running"
       ) do
      {:error, :conversation_busy}
    else
      :ok
    end
  end

  # Names what moved, never a value: these are the conversation's own
  # references to tenant resources, which is what "which selection" means.
  defp reapply_metadata(previous, current) do
    fields = [:agent_id, :agent_version_id, :environment_id, :vault_id, :runtime]

    changed =
      fields
      |> Enum.filter(fn field -> Map.get(previous, field) != Map.get(current, field) end)
      |> Enum.map(&Atom.to_string/1)

    %{
      "changed_fields" => changed,
      "previous" => reapply_selection(previous),
      "current" => reapply_selection(current),
      "configuration_revision" => current.configuration_revision
    }
  end

  defp reapply_selection(conv) do
    %{
      "agent_id" => conv.agent_id,
      "agent_version_id" => conv.agent_version_id,
      "environment_id" => conv.environment_id,
      "vault_id" => conv.vault_id
    }
  end

  # The lock turn admission takes, so a reapply and a turn start cannot
  # interleave on one machine. `nil` is a conversation whose machine has not
  # been minted yet; there is nothing to serialize against.
  defp with_sandbox_lock(sandbox_id, fun) do
    Repo.transaction(fn ->
      if sandbox_id do
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
  end

  @doc """
  Best-effort terminate the running ConversationServer (destroys the sprite
  if alive), then delete the conversation row. Cascades to turns and log
  events via the FK.
  """
  def delete_conversation(%Conversation{id: id, user_id: user_id} = conv, opts \\ []) do
    # `audit: false` on the cascade: this terminate is an implementation
    # detail of deleting, not a second thing the user asked for, and the
    # `conversation.deleted` below already accounts for the sandbox going
    # away. Without it every delete would read as terminate-then-delete.
    _ = Fountain.Conversations.ConversationServer.terminate_conversation(id, audit: false)
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
  to this nonterminal sandbox. An integer capacity also limits concurrent
  turns; `:unbounded` skips only that capacity check. Saved execution allowances
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
              select: %{id: c.id, configuration_revision: c.configuration_revision},
              lock: "FOR UPDATE"
          ) || Repo.rollback(:sandbox_unavailable)

        # The server passes the revision it loaded. A reapply committed since
        # then means this turn would run against settings the server has not
        # read, so it is refused here rather than started wrong (#1565). A
        # caller with no revision to offer is not checked.
        if not is_nil(revision) and conv.configuration_revision != revision do
          Repo.rollback(:configuration_changed)
        end

        attached? =
          Repo.exists?(
            from c in Conversation,
              join: s in Sandbox,
              on: s.id == c.sandbox_id,
              where:
                c.id == ^conv_id and s.id == ^sandbox_id and c.user_id == s.user_id and
                  s.status not in ["terminated", "failed"] and is_nil(s.reset_requested_at)
          )

        unless attached?, do: Repo.rollback(:sandbox_unavailable)

        case _unsafe_check_saved_execution_allowance(conv_id) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        if capacity != :unbounded and
             _unsafe_running_turns_elsewhere(sandbox_id, conv_id) >= capacity do
          Repo.rollback(:sandbox_at_capacity)
        else
          case %Turn{} |> Turn.changeset(attrs) |> Repo.insert() do
            {:ok, turn} -> turn
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end)

    with {:ok, turn} <- result do
      record_turn_usage(turn)
      {:ok, turn}
    end
  end

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

  defp record_execution_allowance_created(allowance, user_id, opts) do
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
          ExecutionLimits.require_controls(normalized, [])
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
  """
  def _unsafe_list_cotenant_ids(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    Repo.all(
      from c in Conversation,
        where:
          c.sandbox_id == ^sandbox_id and c.id != ^conv_id and
            c.status not in ["terminated", "failed"],
        select: c.id
    )
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
    cutoff = now |> DateTime.add(-idle_seconds, :second) |> DateTime.truncate(:second)

    case _unsafe_list_cotenant_ids(sandbox_id, conv_id) do
      [] ->
        false

      cotenants ->
        Repo.exists?(
          from t in Turn,
            where:
              t.conversation_id in ^cotenants and
                (t.status == "running" or t.inserted_at > ^cutoff or t.ended_at > ^cutoff)
        ) or
          Repo.exists?(
            from c in Conversation,
              left_join: t in Turn,
              on: t.conversation_id == c.id,
              where: c.id in ^cotenants and is_nil(t.id) and c.updated_at > ^cutoff
          )
    end
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
    changeset =
      turn
      |> Turn.changeset(attrs)
      |> maybe_put_reply_text(turn)

    result = Repo.update(changeset)

    # The write that *materialises* the reply, not every later update to a
    # turn that already has one — a turn is written again after it ends, and
    # activation happens once.
    with {:ok, updated} <- result,
         text when is_binary(text) <- Ecto.Changeset.get_change(changeset, :reply_text) do
      Fountain.Activation.turn_replied(updated)
    end

    result
  end

  @doc """
  Complete a running turn only on the actor's current sandbox binding.

  Lock the conversation before the turn, and commit its idle status with the
  turn's result. A moved or terminal conversation, or a turn already ended by
  another actor, is a no-op. Reply materialization shares that transaction;
  activation and sidebar publication run after it commits. The optional
  `:exit_code` is persisted atomically with the result.
  """
  def _unsafe_complete_turn(%Turn{} = turn, sandbox_id, status, opts \\ [])
      when status in ["completed", "failed"] do
    end_running_turn(turn, sandbox_id, status, true, Map.new(Keyword.take(opts, [:exit_code])))
  end

  @doc """
  Mark an actor-owned turn interrupted while retaining the conversation's
  status until the peer has stopped. Uses the same binding and terminal guards
  as completion, with reply activation after commit.
  """
  def _unsafe_interrupt_turn(%Turn{} = turn, sandbox_id),
    do: end_running_turn(turn, sandbox_id, "interrupted", false)

  defp end_running_turn(turn, sandbox_id, status, idle?, attrs \\ %{}) do
    {:ok, result} =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^turn.conversation_id, lock: "FOR UPDATE")

        turn_query =
          from(t in Turn,
            where: t.id == ^turn.id and t.conversation_id == ^turn.conversation_id,
            lock: "FOR UPDATE"
          )

        with %Conversation{} = conv <- Repo.one(conversation_query),
             true <- conv.sandbox_id == sandbox_id and conv.status not in ["terminated", "failed"],
             %Turn{status: "running"} = current <- Repo.one(turn_query) do
          changeset =
            current
            |> Turn.changeset(
              Map.merge(attrs, %{
                status: status,
                ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
            )
            |> maybe_put_reply_text(current)

          updated = Repo.update!(changeset)

          updated_conv =
            if idle?,
              do: conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!(),
              else: conv

          {updated, updated_conv, is_binary(Ecto.Changeset.get_change(changeset, :reply_text))}
        else
          _ -> :noop
        end
      end)

    case result do
      :noop ->
        :noop

      {updated, conv, reply_materialized?} ->
        if reply_materialized?, do: Fountain.Activation.turn_replied(updated)
        if idle?, do: broadcast_sidebar_update(conv.user_id)
        {:ok, updated}
    end
  end

  @doc """
  Idle the interrupted turn's conversation after its peer has stopped.

  Recheck the binding, terminal status and interrupted turn under the parent
  lock. A newer running turn keeps the conversation running. The lock matches
  turn admission, so a concurrent admission cannot slip between this check and
  the idle write. No turn row is changed here.
  """
  def _unsafe_idle_interrupted_turn(%Turn{} = turn, sandbox_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^turn.conversation_id, lock: "FOR UPDATE")

        turn_query =
          from(t in Turn,
            where: t.id == ^turn.id and t.conversation_id == ^turn.conversation_id,
            lock: "FOR UPDATE"
          )

        running_query =
          from(t in Turn,
            where: t.conversation_id == ^turn.conversation_id and t.status == "running"
          )

        with %Conversation{} = conv <- Repo.one(conversation_query),
             true <- conv.sandbox_id == sandbox_id and conv.status not in ["terminated", "failed"],
             %Turn{status: "interrupted"} <- Repo.one(turn_query),
             false <- Repo.exists?(running_query) do
          conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!()
        else
          _ -> :noop
        end
      end)

    case result do
      %Conversation{} = conv ->
        broadcast_sidebar_update(conv.user_id)
        :ok

      :noop ->
        :noop
    end
  end

  @doc """
  Finish an actor's machine-gone notification on its current binding.

  Lock the parent through the running-turn check and optional idle write, as
  admission does. A moved, terminal or deleted conversation, or a newer running
  turn, makes this a no-op. Only a running conversation changes status;
  already-idle actors can still record the sandbox event. Publication happens
  after commit, and this function performs no provider or actor I/O.
  """
  def _unsafe_finish_machine_gone(conversation_id, sandbox_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")

        running_query =
          from(t in Turn, where: t.conversation_id == ^conversation_id and t.status == "running")

        with %Conversation{} = conv <- Repo.one(conversation_query),
             true <- conv.sandbox_id == sandbox_id and conv.status not in ["terminated", "failed"],
             false <- Repo.exists?(running_query) do
          if conv.status == "running" do
            {:updated, conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!()}
          else
            :unchanged
          end
        else
          _ -> :noop
        end
      end)

    case result do
      {:updated, conv} ->
        broadcast_sidebar_update(conv.user_id)
        :ok

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
  An actor supplies `:expected_sandbox_id`; after locking the conversation,
  a changed binding makes the entire reconciliation a no-op.
  """
  def _unsafe_orphan_turn(%Turn{} = turn, why, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reply_text = turn.reply_text || _unsafe_turn_reply_text(turn)

    updates =
      [status: "interrupted", ended_at: now, orphaned_at: now]
      |> maybe_set_reply_text(reply_text)

    result =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^turn.conversation_id, lock: "FOR UPDATE")

        turn_query =
          from(t in Turn,
            where:
              t.id == ^turn.id and t.conversation_id == ^turn.conversation_id and
                t.status == "running"
          )

        with %Conversation{} = conv <- Repo.one(conversation_query),
             true <- Keyword.get(opts, :expected_sandbox_id, conv.sandbox_id) == conv.sandbox_id,
             {1, _} <- Repo.update_all(turn_query, set: updates) do
          {conversation_count, _} =
            from(c in Conversation,
              where: c.id == ^conv.id and c.status == "running"
            )
            |> Repo.update_all(set: [status: "idle", updated_at: now])

          {Repo.get!(Turn, turn.id), Repo.reload!(conv), conversation_count == 1}
        else
          _ -> :noop
        end
      end)

    case result do
      {:ok, :noop} ->
        :noop

      {:ok, {updated_turn, conv, conversation_changed?}} ->
        if is_nil(turn.reply_text) and is_binary(updated_turn.reply_text) do
          Fountain.Activation.turn_replied(updated_turn)
        end

        if conversation_changed?, do: broadcast_sidebar_update(conv.user_id)

        publish_stage(turn.conversation_id, "reattach", "interrupted", %{
          outcome: "turn_orphaned",
          turn_id: turn.id,
          turn_number: turn.turn_number,
          reason: why
        })

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
    input = counter_value(Map.get(usage, "input"))
    output = counter_value(Map.get(usage, "output"))

    Repo.transaction(fn ->
      {:ok, updated} = turn |> Turn.changeset(%{usage: usage}) |> Repo.update()

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

  defp maybe_put_reply_text(changeset, %Turn{reply_text: nil} = turn) do
    case Ecto.Changeset.get_change(changeset, :status) do
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
  the transcript uses (`Blocks.assistant_text/2`); nil when there is none.
  Reads the conversation's runtime for the legacy dialects. Without tenant
  scope: the caller holds the turn.
  """
  def _unsafe_turn_reply_text(%Turn{} = turn) do
    runtime =
      Repo.one(from c in Conversation, where: c.id == ^turn.conversation_id, select: c.runtime)

    case turn.id |> _unsafe_list_turn_log_events() |> Blocks.assistant_text(runtime) do
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
  used as the SSE event id).
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

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  defp redact_attrs(%{conversation_id: conv_id, data: data} = attrs)
       when is_binary(conv_id) and is_binary(data) do
    %{attrs | data: Fountain.Conversations.Redaction.redact(conv_id, data)}
  end

  defp redact_attrs(attrs), do: attrs

  @doc """
  Record a stage transition: persist the log event, broadcast it to the
  conversation's PubSub topic, and emit a `[:fountain, :stage]` telemetry
  event.

  Every operationally meaningful outcome flows through here — provision
  done/failed, reattach, turn done/failed — so the Prometheus stage counter
  (and the alert on it) cannot drift from what clients see on the stream.
  `stage` and `status` are the metric's only tags; both value sets are small
  and fixed. `conv_id` stays in metadata and must never become a tag.
  """
  def publish_stage(conv_id, stage, status, meta \\ %{}) do
    event =
      log!(%{
        conversation_id: conv_id,
        kind: "stage",
        stage: stage,
        state: status,
        data: Jason.encode!(meta)
      })

    Fountain.Telemetry.event(
      [:stage],
      %{stage: stage, status: status, conv_id: conv_id},
      %{count: 1}
    )

    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, event})

    # Webhook dispatch hangs off the same call for the same reason the stage
    # counter does (#700): a new lifecycle outcome cannot be added without
    # subscribers seeing it. Best-effort by construction — `dispatch_stage/1`
    # rescues everything, because a webhook that is not sent is a degraded
    # integration and a stage transition that raises is a stuck agent.
    Fountain.Webhooks.dispatch_stage(event)
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
  Returns at most 500 rows in id order, with each conversation's runtime for blocks.
  """
  def list_user_log_events(user_id, after_id) when is_binary(user_id) do
    user_log_events_query(user_id)
    |> where([e], e.id > ^after_id)
    |> order_by([e], asc: e.id)
    |> limit(500)
    |> select([e, c], {e, c.runtime})
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
  Sum the byte sizes of persisted output events for a turn, by stream.
  Used by ConversationServer on reattach to know how many bytes of
  replayed output to skip before persisting fresh, post-disconnect data.
  """
  def _unsafe_output_bytes_by_stream(conversation_id, turn_id) do
    from(e in LogEvent,
      where:
        e.conversation_id == ^conversation_id and
          e.turn_id == ^turn_id and
          e.kind == "output" and
          not is_nil(e.stream),
      group_by: e.stream,
      select: {e.stream, fragment("COALESCE(SUM(LENGTH(?)), 0)", e.data)}
    )
    |> Repo.all()
    |> Map.new()
  end

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

  @doc """
  Like `start_conversation/2`, but a conversation already bound to
  `attrs["channel_id"]` is resumed instead of a new one being opened.

  The channel key is opaque and client-supplied — a Buzz channel id from ACP
  `session/new` `_meta.channelId` (#774). A client that forgets its sessions
  (a restarted `buzz-acp`) then lands back on the same conversation, and so
  the same sandbox and workspace, rather than opening a fresh one per restart.

  Resumes the **latest live** conversation for the same user + agent + vault
  + environment override + channel — `terminated` and `failed` ones are past
  resuming, so a new one is opened and becomes the binding. So is one whose
  *sandbox* is `terminated` or `failed` (#779): the machine is gone, and the
  workspace with it, so the channel gets a new conversation on a working one
  rather than a continuous-looking transcript on a blank disk. A `suspended`
  sandbox is parked, not gone, and still resumes. Returns `{:ok, conv,
  :resumed}` or `{:ok, conv, :created}`; without a `channel_id` it always
  creates.

  `attrs["fresh"]` (`true`) skips the resume this once: the conversation
  currently bound to the channel is unbound (its `channel_id` cleared — it
  keeps running, and the sandbox reaper retires it like any other idle one)
  and a new one is opened as the binding. It is how a chat harness relays its
  owner's `!rotate` — ACP `session/new` `_meta.freshSession` — through a
  binding that would otherwise hand the old conversation straight back.
  Unbinding, rather than relying on "newest wins", keeps the outcome
  independent of `inserted_at`'s one-second precision. Admission commits the
  old unbinding and the replacement together. A refused replacement preserves
  the old binding; a later startup/prompt failure restores it unless another
  rotation has already moved the binding. Concurrent rotations of the same
  binding return a channel validation error to the loser.

  Two concurrent first calls for one channel can both create; the next call
  resumes whichever is newer. Nothing is audited on the resume path unless
  `attrs["labels"]` actually changes something: it is the same conversation,
  so labels merge into the row it hands back (#1637) and that write records
  `conversation.labels_set` like any other.
  """
  def start_or_resume_conversation(attrs, opts \\ [])

  def start_or_resume_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs,
        opts
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         :ok <- check_execution_limits(user_id, attrs["execution_limits"]),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent) do
      case find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id) do
        %Conversation{} = conv ->
          if fresh_requested?(attrs) do
            with {:ok, fresh} <-
                   start_conversation(attrs, Keyword.put(opts, :rotate_from, conv.id)),
                 do: {:ok, fresh, :created}
          else
            with :ok <- _unsafe_check_saved_execution_allowance(conv.id),
                 :ok <- check_sandbox_api_resume(conv, attrs["sandbox_api_access"]),
                 {:ok, conv} <- resume_labels(conv, attrs["labels"], opts),
                 do: {:ok, conv, :resumed}
          end

        nil ->
          with {:ok, conv} <- start_conversation(attrs, opts), do: {:ok, conv, :created}
      end
    end
  end

  def start_or_resume_conversation(attrs, opts) do
    with {:ok, conv} <- start_conversation(attrs, opts), do: {:ok, conv, :created}
  end

  # No runtime has integrated end-to-end enforcement yet. Refuse a requested
  # control before reserving capacity, attaching or unbinding a channel; an
  # SDK option alone must not make admission promise a bounded execution.
  defp check_execution_limits(user_id, request) do
    with {:ok, _limits} <- resolve_admission_limits(user_id, request), do: :ok
  end

  defp resolve_admission_limits(user_id, request) do
    # Ownership: each caller just fetched the agent by this authenticated user.
    # Read the current account policy, never a request-supplied or cached map.
    case {Fountain.Accounts.get_user(user_id),
          Application.get_env(:fountain, :execution_limit_ceiling, %{})} do
      {%Fountain.Accounts.User{execution_limits: ceiling}, host}
      when is_map(ceiling) and is_map(host) ->
        with {:ok, limits} <- ExecutionLimits.resolve(host, ceiling, request),
             :ok <- ExecutionLimits.require_controls(limits, []) do
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
  # Through `set_conversation_labels/4` rather than the writer beneath it:
  # this runs on `POST /api/conversations`, which a sandbox's own token may
  # call, and a resume names an *existing* conversation. Writing here
  # directly would let a sprite minted for one conversation relabel any other
  # of the tenant's by resuming its channel.
  defp resume_labels(%Conversation{} = conv, nil, _opts), do: {:ok, conv}

  defp resume_labels(%Conversation{} = conv, labels, opts),
    do: set_conversation_labels(conv.id, conv.user_id, labels, opts)

  # `true` or `"true"` — the ACP adapter sends a JSON boolean, a hand-built
  # request may send a string. Anything else is not a request.
  defp fresh_requested?(%{"fresh" => fresh}), do: fresh in [true, "true"]
  defp fresh_requested?(_attrs), do: false

  # The rotated-away conversation stops being the channel's binding. Nothing
  # else about it changes: if it is mid-turn it finishes, and it stays in the
  # user's list under its own id.
  defp unbind_channel(%Conversation{} = conv) do
    conv
    |> Ecto.Changeset.change(channel_id: nil)
    |> Repo.update()
  end

  # Inside admission's transaction, before the attachment's sandbox row lock.
  # Keep the selected conversation stable while replacing its binding; reject
  # a competing rotation that has already moved it.
  defp unbind_rotated_channel(attrs, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil ->
        :ok

      id ->
        case lock_rotation_conversation(id, attrs) do
          %Conversation{channel_id: channel} = conv when channel == attrs.channel_id ->
            with {:ok, _} <- unbind_channel(conv), do: :ok

          :busy ->
            {:error, rotation_conflict("the previous conversation is busy; retry the rotation")}

          _ ->
            {:error, rotation_conflict("binding changed; retry the rotation")}
        end
    end
  end

  # Worker startup and attachment prompt delivery run after admission commits.
  # Restore only while this replacement still owns the binding; a later
  # rotation must win over this failure. Keep the old -> new row lock order.
  defp restore_rotated_channel(conv, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil -> :ok
      id -> report_restore(conv, id, attempt_restore(conv, id))
    end
  end

  defp attempt_restore(conv, id) do
    Repo.transaction(fn ->
      with %Conversation{channel_id: nil} = previous <- lock_rotation_conversation(id, conv),
           %Conversation{channel_id: channel} = replacement
           when channel == conv.channel_id <- lock_rotation_conversation(conv.id, conv) do
        replacement |> Ecto.Changeset.change(channel_id: nil) |> Repo.update!()
        previous |> Ecto.Changeset.change(channel_id: channel) |> Repo.update!()
        :restored
      else
        # Contention on a row this compensation cannot wait for.
        :busy -> Repo.rollback(:busy)
        # A newer rotation already owns the binding, or the rows moved. That
        # rotation must win over this failure, so leaving them alone is right.
        _ -> :superseded
      end
    end)
  rescue
    e -> {:error, e}
  end

  defp report_restore(_conv, _id, {:ok, _outcome}), do: :ok

  # A compensation, not a rollback: nothing retries it and no caller can act on
  # it. Failing silently leaves a channel bound to nothing, which is the bug
  # this path exists to prevent wearing a different hat, so say so.
  defp report_restore(conv, id, other) do
    Logger.warning(
      "conv #{conv.id}: could not restore channel #{inspect(conv.channel_id)} to conv #{id} " <>
        "after a failed rotation: #{inspect(other)}"
    )

    :ok
  end

  defp rotation_conflict(message) do
    %Conversation{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:channel_id, message)
  end

  # How long a rotation may wait for the row it is replacing. On the fresh path
  # this runs inside `with_sandbox_reservation/3`, which holds the global fleet
  # advisory lock, and the row it wants is the one `_unsafe_create_turn_on_sandbox/3`
  # takes `FOR UPDATE` — so an unbounded wait would let one busy channel stall
  # provisioning for every tenant. Turn admission holds that row for a handful
  # of local queries, so this is orders of magnitude more than it ever
  # legitimately needs, and exceeding it means contention worth reporting
  # rather than waiting out.
  @rotation_lock_timeout_ms 250

  defp lock_rotation_conversation(id, attrs) do
    # Channel/ownership writes must serialize, but FK references may proceed.
    #
    # The bound is scoped to this read and handed straight back: `SET LOCAL`
    # lasts for the whole transaction, and admission goes on to insert rows
    # whose foreign keys take `KEY SHARE` on `users` — which a credit posting's
    # `FOR UPDATE` conflicts with. Leaving 250ms in force over those would turn
    # a slow billing write into an unrescued error on a path that has none.
    Repo.query!("SET LOCAL lock_timeout = '#{@rotation_lock_timeout_ms}ms'")

    conversation =
      from(c in Conversation,
        where: c.id == ^id and c.user_id == ^attrs.user_id and c.agent_id == ^attrs.agent_id,
        lock: "FOR NO KEY UPDATE"
      )
      |> where_vault(attrs.vault_id)
      |> where_environment(attrs.environment_id)
      |> Repo.one()

    Repo.query!("SET LOCAL lock_timeout = DEFAULT")
    conversation
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :lock_not_available do
        :busy
      else
        reraise(e, __STACKTRACE__)
      end
  end

  # The newest conversation still worth resuming for this binding. `vault_id`
  # is part of the key: two entries on one agent with different vaults are
  # different identities (#727) and must not share a conversation. So is the
  # environment override (#783): an identity that switches environments must
  # not resume a conversation provisioned from the old one.
  #
  # The sandbox is part of it too (#779): the 24 hour ceiling destroys a
  # sandbox while its conversation stays `idle`, and resuming that row wakes
  # onto a *fresh* machine with the workspace gone (#778 makes the turn work;
  # #936 is the memory it loses) inside a transcript that reads as continuous.
  # A channel is better served by a new conversation on a working machine, so
  # the binding follows the machine, not just the conversation row.
  # `suspended` is not in the list: that sandbox is parked, not gone, and its
  # disk wakes back up with the workspace on it.
  @doc """
  The conversation a channel binding resumes, resolved exactly as
  `start_or_resume_conversation/2` resolves it (same vault/environment key),
  without opening one when there is none. For a request that must land on an
  existing conversation or fail — a tool answer on the bridge (#1202) — where
  opening a sandbox for a thread that has no parked call would be the wrong
  side effect. Tenant-scoped through `attrs["user_id"]`.
  """
  @spec channel_conversation(map()) :: Conversation.t() | nil
  def channel_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent) do
      find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id)
    else
      _ -> nil
    end
  end

  def channel_conversation(_attrs), do: nil

  defp find_channel_conversation(user_id, agent_id, vault_id, env_id, channel_id) do
    from(c in Conversation,
      join: s in assoc(c, :sandbox),
      where:
        c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^channel_id and
          c.status not in ["terminated", "failed"] and
          s.status not in ["terminated", "failed"],
      order_by: [desc: c.inserted_at],
      limit: 1
    )
    |> where_vault(vault_id)
    |> where_environment(env_id)
    |> Repo.one()
  end

  defp where_vault(query, nil), do: from(c in query, where: is_nil(c.vault_id))
  defp where_vault(query, vault_id), do: from(c in query, where: c.vault_id == ^vault_id)

  defp where_environment(query, nil), do: from(c in query, where: is_nil(c.environment_id))
  defp where_environment(query, id), do: from(c in query, where: c.environment_id == ^id)

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`              — agent to run
    - `prompt`                — optional first prompt (sends turn 1 immediately)
    - `sprite_name`           — optional override; defaults to "fountain-<short-user-id>-<short-id>"
    - `vault_id`              — optional vault whose secrets override the env's
    - `environment_id`        — optional environment to provision from instead of the
                                agent's own (#783); subject to `agent.allowed_environment_ids`
    - `permission_policy`     — optional per-tool permission override (#939); may only
                                narrow the agent's own policy, never widen it
    - `sandbox_api_access`    — "owner" (default) or "none"; none requires a fresh ephemeral sandbox
    - `source`                — optional; one of "ui", "api", "agent" (default "api")
    - `parent_conversation_id` — optional; UUID of the conversation that spawned this one
    - `title`                 — optional display title (the team page names a teammate with it)
    - `labels`                — optional `key => value` strings (#1637); see `Conversations.Labels`
  """
  def start_conversation(attrs, opts \\ [])

  # `sandbox_id`: attach to a machine the caller already has instead of
  # provisioning one (ADR 0023 gate 3). Everything about the launch is
  # resolved the same way; only the sandbox step differs.
  def start_conversation(%{"sandbox_id" => sandbox_id} = attrs, opts)
      when is_binary(sandbox_id) and sandbox_id != "" do
    attach_conversation(sandbox_id, attrs, opts)
  end

  def start_conversation(%{"agent_id" => agent_id, "user_id" => user_id} = attrs, opts)
      when is_binary(user_id) do
    with :ok <- require_provider_commit_boundary(),
         :ok <- Fountain.Conversations.PromptInput.validate_initial(attrs),
         %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         :ok <- check_execution_limits(user_id, attrs["execution_limits"]),
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, mode} <- resolve_sandbox_mode(attrs["sandbox_mode"], agent),
         {:ok, api_access} <- resolve_sandbox_api_access(attrs["sandbox_api_access"], mode),
         {:ok, perm_policy} <- resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, parent_id} <- resolve_parent_id(attrs["parent_conversation_id"], user_id),
         :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_spend(user_id),
         # Whose inference key would run this (#1388): refused only when it
         # would be Fountain's and the deployment has spent its day. A door
         # with no platform key configured runs no query here.
         :ok <- Fountain.PlatformInference.gate(user_id, agent.model, agent.runtime),
         # A persistent launch lands on the identity's home when there is one
         # (ADR 0023 gate 6): `{:home, sandbox}` leaves the `with` and attaches
         # below. Only when there is none does a machine get provisioned, and
         # it is stamped as the home.
         :new <- home_or_new(mode, user_id, agent, env_id || agent.environment_id, vault_id),
         {:ok, provider} <- resolve_sandbox_provider(agent),
         {:ok, sprite_name} <- mint_sprite_name(provider, user_id, attrs["sprite_name"]),
         {:ok, {sandbox, conv, allowance}} <-
           reserve_initial_conversation(
             %{
               environment_id: env_id || agent.environment_id,
               # The identity the disk is built from (ADR 0023); an attach
               # later must name the same three.
               agent_id: agent.id,
               vault_id: vault_id,
               mode: mode,
               sprite_name: sprite_name,
               status: "pending",
               provider: Atom.to_string(provider),
               user_id: user_id
             },
             %{
               agent_id: agent.id,
               # Ownership: agent came from the scoped get_agent above.
               agent_version_id: Agents._unsafe_current_version_id(agent.id),
               vault_id: vault_id,
               environment_id: env_id,
               user_id: user_id,
               runtime: agent.runtime,
               status: "pending",
               source: attrs["source"] || "api",
               parent_conversation_id: parent_id,
               channel_id: attrs["channel_id"],
               title: attrs["title"],
               sandbox_api_access: api_access,
               permission_policy: perm_policy,
               caller_tools: attrs["caller_tools"] || [],
               labels: attrs["labels"] || %{}
             },
             attrs["execution_limits"],
             opts
           ) do
      after_conversation_created(conv)
      record_execution_allowance_created(allowance, user_id, opts)

      # Recorded here rather than in either branch below: both of them return
      # {:ok, conv}. The row exists and the sandbox reservation is spent even
      # when the server fails to start, so "a conversation was created" is
      # true either way, and a trail that only logged the happy path would
      # under-report exactly the runs someone is trying to explain.
      #
      # The prompt is described, never quoted — see `send_prompt/4`.
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent.id,
          "agent_name" => agent.name,
          "source" => conv.source,
          "with_prompt" => is_binary(attrs["prompt"]) and attrs["prompt"] != "",
          "parent_conversation_id" => parent_id
        }
      })

      # No prompt in the child spec — see start_conversation_server/4.
      start_result =
        Horde.DynamicSupervisor.start_child(
          Fountain.ConversationSupervisor,
          {ConversationServer,
           [
             conversation_id: conv.id,
             sandbox_id: sandbox.id,
             runtime_module: runtime_module
           ]}
        )

      case start_result do
        {:ok, pid} ->
          if is_binary(attrs["prompt"]) and attrs["prompt"] != "" do
            ConversationServer.queue_initial_prompt(
              pid,
              attrs["prompt"],
              attrs["images"] || []
            )
          end

          result = _unsafe_get_conversation!(conv.id)

          if result.parent_conversation_id do
            root_id = get_root_conversation_id(result.id)
            broadcast_graph_update(root_id)
          end

          broadcast_sidebar_update(user_id)
          {:ok, result}

        {:error, reason} ->
          # The conversation row was created successfully; mark it and its
          # sandbox failed so the status is visible on the conversation page,
          # then return it so callers (UI + API) navigate there rather than
          # leaving the user stuck on the new-conversation form.
          Logger.error(
            "ConversationServer failed to start for conv #{conv.id}: #{inspect(reason)}"
          )

          if fail_initial_start(conv, sandbox) == :failed,
            do: restore_rotated_channel(conv, opts)

          case get_conversation(conv.id, user_id) do
            nil ->
              {:error, :not_found}

            result ->
              broadcast_sidebar_update(user_id)
              {:ok, result}
          end
      end
    else
      nil ->
        {:error, :not_found}

      # The identity already has a home: this launch is a conversation on it.
      {:home, %Sandbox{} = home} ->
        attach_conversation(home.id, attrs, opts)

      # Two persistent launches of one identity raced to create its home and
      # this one lost at the unique index. The winner's row is the home now;
      # land on it rather than fail a request that asked for nothing unusual.
      {:error, %Ecto.Changeset{errors: errors}} = err ->
        if Keyword.has_key?(errors, :home) do
          with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
               {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
               {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent),
               %Sandbox{} = home <-
                 _unsafe_find_home(user_id, agent.id, env_id || agent.environment_id, vault_id) do
            attach_conversation(home.id, attrs, opts)
          else
            _ -> err
          end
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  # Tenant row waits happen here, before the fleet lock, and the reservation
  # runs inside them. `with_sandbox_reservation/3` holds
  # `pg_advisory_xact_lock(@fleet_lock_key)` — one lock shared by every tenant —
  # so anything that can wait on another transaction must be settled before it
  # is taken, or one account stalls provisioning for all of them.
  #
  # A delayed start error owns only its original, still-pending binding.
  # Match turn admission's machine -> parent -> sandbox lock order. Status
  # changes commit together; metering follows commit and provider I/O is absent.
  defp fail_initial_start(conv, sandbox) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          :erlang.phash2(sandbox.id)
        ])

        parent = Repo.one(from c in Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE")
        machine = Repo.one(from s in Sandbox, where: s.id == ^sandbox.id, lock: "FOR UPDATE")

        if pending_initial_binding?(parent, machine, conv, sandbox) and
             _unsafe_running_turns_elsewhere(sandbox.id, nil) == 0 do
          parent |> Conversation.changeset(%{status: "failed"}) |> Repo.update!()

          machine
          |> Sandbox.changeset(%{status: "failed"})
          |> stamp_terminated_at()
          |> Repo.update!()
        else
          :stale
        end
      end)

    case result do
      %Sandbox{} = failed ->
        record_sandbox_usage("pending", failed)
        :failed

      :stale ->
        :stale
    end
  end

  defp pending_initial_binding?(%Conversation{} = parent, %Sandbox{} = machine, conv, sandbox) do
    Map.take(parent, [:user_id, :sandbox_id, :status]) ==
      %{user_id: conv.user_id, sandbox_id: sandbox.id, status: "pending"} and
      Map.take(machine, [:user_id, :provider, :sprite_name, :status]) ==
        %{
          user_id: conv.user_id,
          provider: sandbox.provider,
          sprite_name: sandbox.sprite_name,
          status: "pending"
        }
  end

  defp pending_initial_binding?(_, _, _, _), do: false

  # An unlocked read was not enough: `create_sandbox/1` and the conversation
  # insert take `KEY SHARE` on `users` through their foreign keys, and
  # `Credits.insert_and_move/3` holds that row `FOR UPDATE` across a ledger
  # insert, lot consumption and the balance move. Taking `FOR SHARE` out here
  # both settles the wait outside the fleet lock and satisfies those foreign
  # keys, so the inserts below cannot block on it. The rotation unbind is the
  # same category of wait and joins them.
  #
  # This is one transaction: the nested `Repo.transaction` inside
  # `with_sandbox_reservation/3` joins it rather than opening another, so the
  # sandbox, conversation and allowance still commit or roll back together.
  # That is also why the `case` below re-raises the inner rollback with its
  # reason: a nested rollback the outer transaction does not re-raise reaches
  # the caller as `{:error, :rollback}`, which would turn every credits, quota
  # and fleet refusal into a 500 instead of a 402, 422 or 503.
  #
  # The wait does not disappear, it changes hands. This transaction holds
  # `users FOR SHARE` for its whole life, the fleet-lock wait included, and
  # `FOR SHARE` conflicts with `FOR UPDATE` — so this tenant's credit postings
  # now queue behind its own in-flight launch, which may itself be queued
  # behind every other tenant's. Turn burns, purchases, grants, expiry and
  # refund clawbacks all post through `Credits.insert_and_move/3`. A
  # tenant-scoped wait beats a fleet-wide one, which is why it is the right
  # trade, but a slow credit posting starts here.
  defp reserve_initial_conversation(sandbox_attrs, conversation_attrs, request, opts) do
    Repo.transaction(fn ->
      Repo.one(
        from u in Fountain.Accounts.User,
          where: u.id == ^conversation_attrs.user_id,
          select: u.id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

      Repo.one(
        from a in Agents.Agent,
          where:
            a.id == ^conversation_attrs.agent_id and a.user_id == ^conversation_attrs.user_id,
          select: a.id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

      case unbind_rotated_channel(conversation_attrs, opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      result =
        Fountain.Quotas.with_sandbox_reservation(conversation_attrs.user_id, fn ->
          with {:ok, limits} <- resolve_admission_limits(conversation_attrs.user_id, request),
               {:ok, sandbox} <- create_sandbox(sandbox_attrs),
               {:ok, conv} <-
                 insert_conversation_row(Map.put(conversation_attrs, :sandbox_id, sandbox.id)),
               {:ok, allowance} <-
                 conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert() do
            {:ok, {sandbox, conv, allowance}}
          end
        end)

      case result do
        {:ok, reserved} -> reserved
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp resolve_sandbox_api_access(access, _mode) when access in [nil, "owner"],
    do: {:ok, "owner"}

  defp resolve_sandbox_api_access("none", "ephemeral"), do: {:ok, "none"}
  defp resolve_sandbox_api_access(_access, _mode), do: {:error, :invalid_sandbox_api_access}

  defp check_sandbox_api_resume(_conv, nil), do: :ok
  defp check_sandbox_api_resume(%Conversation{sandbox_api_access: access}, access), do: :ok
  defp check_sandbox_api_resume(_conv, _access), do: {:error, :invalid_sandbox_api_access}

  defp check_sandbox_api_attach(sandbox, access) do
    # A fresh none launch must never inherit another conversation's credential,
    # and attaching an owner conversation must not inject one into its machine.
    has_none =
      Repo.exists?(
        from(c in Conversation,
          where: c.sandbox_id == ^sandbox.id and c.sandbox_api_access == "none"
        )
      )

    if access in [nil, "owner"] and not has_none,
      do: :ok,
      else: {:error, :invalid_sandbox_api_access}
  end

  # The launch's sandbox mode: the agent's default unless the launch names
  # one (ADR 0023). Not an allowlisted override like `environment_id` — the
  # mode is not a security boundary; the tenant scope on the sandbox is.
  defp resolve_sandbox_mode(mode, %Agents.Agent{sandbox_mode: default}) when mode in [nil, ""],
    do: {:ok, default || "ephemeral"}

  defp resolve_sandbox_mode(mode, _agent) when is_binary(mode) do
    if mode in Sandbox.modes(), do: {:ok, mode}, else: {:error, :invalid_sandbox_mode}
  end

  defp resolve_sandbox_mode(_mode, _agent), do: {:error, :invalid_sandbox_mode}

  # `:new` when a machine has to be provisioned; `{:home, sandbox}` when the
  # identity already has one to land on. A home still provisioning from its
  # first launch cannot take a second conversation yet — its prompt would be
  # handed to the wrong server — so it reads as `:provisioning`, the same
  # retry-shortly answer a mid-provision conversation gives.
  defp home_or_new("ephemeral", _user_id, _agent, _env_id, _vault_id), do: :new

  defp home_or_new("persistent", user_id, %Agents.Agent{id: agent_id}, env_id, vault_id) do
    case _unsafe_find_home(user_id, agent_id, env_id, vault_id) do
      nil -> :new
      %Sandbox{status: s} when s in ["pending", "starting"] -> {:error, :provisioning}
      %Sandbox{} = home -> {:home, home}
    end
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
  Whether terminating `conv_id` leaves its sandbox standing: a home is never
  torn down by one conversation ending (ADR 0023 step 5), and neither is a
  machine another live conversation still holds. Both `ConversationServer`
  terminate paths ask this. `_unsafe_`: the caller owns `conv_id`.
  """
  def _unsafe_sandbox_kept_on_terminate?(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    case _unsafe_get_sandbox(sandbox_id) do
      %Sandbox{mode: "persistent"} -> true
      _ -> _unsafe_sandbox_held_by_other?(sandbox_id, conv_id)
    end
  end

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
  Tear down every home of `agent_id` — what deleting the agent does, since
  the identity the homes were built for is gone (ADR 0023 step 5). Each live
  conversation on a home is terminated (a home survives that on its own), then
  the sprite is destroyed and the row terminated. Best-effort per machine; a
  provider error is logged and the row still retires, so the reaper's sweep
  sees a terminal row rather than a live one nobody can find. Returns the
  number of homes torn down, or a fencing error. Refuses an enclosing database
  transaction before any teardown. Admission is fenced before actor shutdown
  and provider I/O; already admitted turns may be interrupted by this forced
  operation. `_unsafe_`: the caller owns the agent.
  """
  def _unsafe_destroy_homes_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      from(s in Sandbox,
        where:
          s.agent_id == ^agent_id and s.mode == "persistent" and
            s.status not in ["terminated", "failed"]
      )
      |> Repo.all()
      |> Enum.reduce_while(0, fn home, count ->
        case _unsafe_destroy_home(home, Keyword.put_new(opts, :reason, "agent_deleted")) do
          :ok -> {:cont, count + 1}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def _unsafe_destroy_home(%Sandbox{} = sandbox, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with {:ok, fenced} <- _unsafe_fence_sandbox_for_teardown(sandbox, opts) do
        fenced = Repo.preload(fenced, :conversations)

        fenced.conversations
        |> Enum.reject(&(&1.status in ["terminated", "failed"]))
        |> Enum.each(
          &ConversationServer.terminate_conversation(&1.id, actor: "system:home_reset")
        )

        _unsafe_retire_home(fenced)
      end
    end
  end

  @doc """
  Commit an admission fence before a caller tears down a sandbox. No provider
  I/O runs here. The caller owns this row and must stop actors and clean up
  the provider after success. Already admitted turns may be forcibly stopped.

  Reuses the reset fence so every existing reuse path refuses the machine,
  retaining capacity until retirement completes. `teardown_requested_at`
  distinguishes forced teardown from an ordinary reset. A new forced intent
  records `sandbox.teardown_requested` after commit; repeats preserve both
  timestamps. Escalating an existing reset preserves its admission fence.
  Refuses an enclosing transaction. `opts` carries actor, request_ip and reason.

  With a terminating_conversation_id, first lock and verify that conversation's
  current attachment and owner. A persistent home or another live conversation
  returns {:error, :sandbox_kept} without a new fence. The sandbox row stays
  locked through this decision and the fence, serializing supported attachments.
  """
  def _unsafe_fence_sandbox_for_teardown(%Sandbox{} = sandbox, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case do_fence_sandbox_for_teardown(sandbox, Keyword.get(opts, :terminating_conversation_id)) do
        {:ok, {fenced, true}} ->
          Audit.record(%{
            user_id: fenced.user_id,
            action: "sandbox.teardown_requested",
            resource_type: "sandbox",
            resource_id: fenced.id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: %{
              "reason" => Keyword.get(opts, :reason, "teardown"),
              "provider" => fenced.provider
            }
          })

          {:ok, fenced}

        {:ok, {fenced, false}} ->
          {:ok, fenced}

        {:error, _} = error ->
          error
      end
    end
  end

  defp do_fence_sandbox_for_teardown(sandbox, ending_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @sandbox_lock_namespace,
        :erlang.phash2(sandbox.id)
      ])

      # Match admission's advisory -> conversation -> sandbox lock order.
      lock_terminating_conversation(sandbox, ending_id)

      current =
        Repo.one(from s in Sandbox, where: s.id == ^sandbox.id, lock: "FOR UPDATE") ||
          Repo.rollback(:not_found)

      if not is_nil(ending_id) and
           (current.mode == "persistent" or _unsafe_sandbox_held_by_other?(current.id, ending_id)) do
        Repo.rollback(:sandbox_kept)
      end

      # Forced teardown may stop an admitted turn. Keep the admission fence
      # and its timestamp when an ordinary reset is escalated to forced teardown.
      cond do
        current.status in @billable_terminal ->
          {current, false}

        is_nil(current.teardown_requested_at) ->
          now = DateTime.utc_now()

          fenced =
            current
            |> Ecto.Changeset.change(
              reset_requested_at: current.reset_requested_at || now,
              teardown_requested_at: now
            )
            |> Repo.update!()

          {fenced, true}

        true ->
          {current, false}
      end
    end)
  end

  defp lock_terminating_conversation(_sandbox, nil), do: :ok

  defp lock_terminating_conversation(sandbox, ending_id) when is_binary(ending_id) do
    Repo.one(
      from c in Conversation,
        where:
          c.id == ^ending_id and c.sandbox_id == ^sandbox.id and c.user_id == ^sandbox.user_id,
        select: c.id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:sandbox_unavailable)
  end

  # Destroy the sprite behind a home and retire its row. Best-effort on the
  # provider side: a destroy error is logged and the row still goes
  # `terminated`, so the reaper's sweep sees a terminal row rather than a
  # live one nobody can find. What happens to the conversations on the home
  # is the caller's decision — agent delete terminates them, a reset keeps
  # them.
  defp _unsafe_retire_home(%Sandbox{} = sandbox) do
    handle = Managoat.Sandbox.build_handle(sandbox_provider_atom(sandbox), sandbox.sprite_name)

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("home #{sandbox.sprite_name} destroy failed: #{inspect(reason)}")
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, _} = update_sandbox(sandbox, %{status: "terminated", terminated_at: now})
    :ok
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
  the operator's to check. There is no automatic reconciliation.

  Two audit rows, not one: `sandbox.reset_requested` when the fence commits,
  and `sandbox.reset` only when the provider confirms the destroy.

  `opts[:reason]` says *why*, and reaches every transcript on the machine and
  the audit row: `"home_reset"` (the owner asked — the default),
  `"environment_changed"`, `"environment_deleted"`, `"vault_deleted"` or
  `"teammate_rebound"` when the identity moved out from under the home
  (#1084, #1636).

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
         {:ok, completed} <- finish_sandbox_reset(fenced) do
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
              by: "owner",
              message: message
            })

          pid ->
            GenServer.cast(pid, {:machine_gone, "reset", reason, message})
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
  # the committed fence intact; neither a repeat reset nor the reaper retries it.
  defp finish_sandbox_reset(sandbox) do
    handle = Managoat.Sandbox.build_handle(sandbox_provider_atom(sandbox), sandbox.sprite_name)

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        changeset = sandbox |> Sandbox.changeset(%{status: "terminated"}) |> stamp_terminated_at()

        with {:ok, completed} <- Repo.update(changeset) do
          record_sandbox_usage(sandbox.status, completed)
          {:ok, completed}
        end

      {:error, _} ->
        {:error, :sandbox_reset_pending}
    end
  end

  # What each transcript on a reset home is told. The tail is the same every
  # time — the transcript survives, the next prompt builds a machine — because
  # that is the part a reader needs; the head says whose decision it was.
  @reset_tail "The transcript is kept; the next prompt builds a fresh machine, " <>
                "and the agent starts a new session there."

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

  # A conversation on a machine the caller already has (ADR 0023 gate 3).
  #
  # The launch is resolved exactly as a fresh one — agent, vault, environment,
  # permission policy, parent, the account and billing gates — and then the
  # sandbox is fetched tenant-scoped and checked instead of created: it must
  # be `ready` or `suspended`, it must have been built for the same agent,
  # environment and vault, and the runtime that shaped its disk must be the
  # agent's runtime still. No quota reservation: nothing new is provisioned,
  # and waking a `suspended` machine goes through the quota gate on the first
  # prompt as every wake does. The conversation is opened `idle` with no
  # server; a prompt supplied here is delivered through the ordinary wake
  # path, so a `ready` machine reattaches and a `suspended` one resumes, and
  # if that delivery is refused the row is removed again so a refused request
  # creates nothing.
  defp attach_conversation(
         sandbox_id,
         %{"agent_id" => agent_id, "user_id" => user_id} = attrs,
         opts
       )
       when is_binary(user_id) do
    with :ok <- require_provider_commit_boundary(),
         :ok <- Fountain.Conversations.PromptInput.validate_initial(attrs),
         %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         :ok <- check_execution_limits(user_id, attrs["execution_limits"]),
         {:ok, _runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         {:ok, vault_id} <- resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <- resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, perm_policy} <- resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, parent_id} <- resolve_parent_id(attrs["parent_conversation_id"], user_id),
         :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_spend(user_id),
         # Whose inference key would run this (#1388): refused only when it
         # would be Fountain's and the deployment has spent its day. A door
         # with no platform key configured runs no query here.
         :ok <- Fountain.PlatformInference.gate(user_id, agent.model, agent.runtime),
         %Sandbox{} = sandbox <- get_sandbox(sandbox_id, user_id) || {:error, :sandbox_not_found},
         :ok <- check_sandbox_api_attach(sandbox, attrs["sandbox_api_access"]),
         :ok <- check_attachable(sandbox, agent, vault_id, env_id),
         :ok <- check_attach_capacity(sandbox, agent, attrs["prompt"]),
         {:ok, conv} <-
           create_attached_conversation(
             %{
               sandbox_id: sandbox.id,
               agent_id: agent.id,
               # Ownership: agent came from the scoped get_agent above.
               agent_version_id: Agents._unsafe_current_version_id(agent.id),
               vault_id: vault_id,
               environment_id: env_id,
               user_id: user_id,
               runtime: agent.runtime,
               status: "idle",
               source: attrs["source"] || "api",
               parent_conversation_id: parent_id,
               channel_id: attrs["channel_id"],
               title: attrs["title"],
               permission_policy: perm_policy,
               # The bridge's tools (#1202) ride on both create paths: this
               # one is what a home sandbox's second conversation takes.
               caller_tools: attrs["caller_tools"] || [],
               labels: attrs["labels"] || %{}
             },
             attrs["execution_limits"],
             opts
           ) do
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent.id,
          "agent_name" => agent.name,
          "source" => conv.source,
          "with_prompt" => is_binary(attrs["prompt"]) and attrs["prompt"] != "",
          "parent_conversation_id" => parent_id,
          "sandbox_attached" => sandbox.id
        }
      })

      broadcast_sidebar_update(user_id)
      deliver_attach_prompt(conv, attrs, opts)
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # Commit policy with the new conversation, before analytics, audit or prompt
  # delivery. Lock its owners and recheck ceilings after the early preflight.
  defp create_attached_conversation(attrs, request, opts) do
    result =
      Repo.transaction(fn ->
        # Deliberately unlocked. `users` is the row every credit posting takes
        # `FOR UPDATE` (`Credits.insert_and_move/3` holds it across a ledger
        # insert, lot consumption and the balance move), so locking it here
        # would park admission behind an unrelated billing transaction. This
        # read is an ownership recheck; the ceiling below is read the same way,
        # and the insert's foreign keys are what actually enforce integrity.
        Repo.one(
          from u in Fountain.Accounts.User,
            where: u.id == ^attrs.user_id,
            select: u.id
        ) || Repo.rollback(:not_found)

        agent =
          Repo.one(
            from a in Agents.Agent,
              where: a.id == ^attrs.agent_id and a.user_id == ^attrs.user_id,
              lock: "FOR SHARE"
          ) || Repo.rollback(:not_found)

        case unbind_rotated_channel(attrs, opts) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        sandbox =
          Repo.one(
            from s in Sandbox,
              where: s.id == ^attrs.sandbox_id and s.user_id == ^attrs.user_id,
              lock: "FOR SHARE"
          ) || Repo.rollback(:not_found)

        with :ok <- check_attachable(sandbox, agent, attrs.vault_id, attrs.environment_id),
             {:ok, limits} <- resolve_admission_limits(attrs.user_id, request),
             {:ok, conv} <- insert_conversation_row(attrs),
             {:ok, allowance} <-
               conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert() do
          {conv, allowance}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {conv, allowance}} <- result do
      after_conversation_created(conv)
      record_execution_allowance_created(allowance, conv.user_id, opts)
      {:ok, conv}
    end
  end

  # A nested transaction does not commit: workers and provider calls must not
  # escape a caller's transaction that can still roll back the accepted rows.
  defp require_provider_commit_boundary do
    if Repo.in_transaction?(), do: {:error, :provider_transaction_open}, else: :ok
  end

  defp deliver_attach_prompt(conv, attrs, opts) do
    prompt = attrs["prompt"]

    if is_binary(prompt) and prompt != "" do
      case ConversationServer.send_prompt(conv.id, prompt, attrs["images"] || [], opts) do
        :ok ->
          {:ok, _unsafe_get_conversation!(conv.id)}

        {:error, _} = err ->
          # Nothing ran. Take the row back so a refused request created
          # nothing, exactly like a refused fresh launch.
          restore_rotated_channel(conv, opts)
          _ = Repo.delete(conv)
          broadcast_sidebar_update(conv.user_id)
          err
      end
    else
      {:ok, _unsafe_get_conversation!(conv.id)}
    end
  end

  defp check_attachable(%Sandbox{reset_requested_at: at}, _agent, _vault_id, _env_id)
       when not is_nil(at),
       do: {:error, :sandbox_reset_pending}

  defp check_attachable(%Sandbox{status: status}, _agent, _vault_id, _env_id)
       when status not in ["ready", "suspended"],
       do: {:error, {:sandbox_not_attachable, status}}

  defp check_attachable(%Sandbox{} = sandbox, %Agents.Agent{} = agent, vault_id, env_id) do
    cond do
      sandbox.agent_id != agent.id ->
        {:error, :sandbox_identity_mismatch}

      sandbox.vault_id != vault_id ->
        {:error, :sandbox_identity_mismatch}

      sandbox.environment_id != (env_id || agent.environment_id) ->
        {:error, :sandbox_identity_mismatch}

      # The disk was shaped by the runtime that first ran on it; an agent
      # whose runtime changed since gets a new machine, not this one.
      _unsafe_sandbox_runtime(sandbox.id) not in [nil, agent.runtime] ->
        {:error, :sandbox_runtime_mismatch}

      true ->
        :ok
    end
  end

  # With a prompt, the attach is a turn start too, so the capacity rule of
  # step 4 applies at the door; without one, the later prompt is gated by
  # `ConversationServer` as any prompt is.
  defp check_attach_capacity(%Sandbox{} = sandbox, %Agents.Agent{runtime: runtime}, prompt)
       when is_binary(prompt) and prompt != "" do
    capacity = Fountain.RuntimeDispatch.concurrency(runtime)

    if _unsafe_sandbox_at_capacity?(sandbox.id, nil, capacity),
      do: {:error, :sandbox_at_capacity},
      else: :ok
  end

  defp check_attach_capacity(_sandbox, _agent, _prompt), do: :ok

  @doc "The runtime of the newest conversation on `sandbox_id`, or nil when it has none."
  def _unsafe_sandbox_runtime(sandbox_id) when is_binary(sandbox_id) do
    Repo.one(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 1,
        select: c.runtime
    )
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

  # sobelow_skip ["SQL.Query"] — static SQL with a bound $1 UUID parameter.
  # sobelow_skip ["SQL.Query"] — static SQL with a bound $1 UUID parameter.
  defp get_root_conversation_id(conversation_id) do
    sql = """
    WITH RECURSIVE ancestors(id, parent_conversation_id) AS (
      SELECT id, parent_conversation_id FROM conversations WHERE id = $1
      UNION ALL
      SELECT c.id, c.parent_conversation_id FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
    )
    SELECT id FROM ancestors WHERE parent_conversation_id IS NULL LIMIT 1
    """

    {:ok, uuid} = Ecto.UUID.dump(conversation_id)

    case Repo.query!(sql, [uuid]) do
      %{rows: [[root_id]]} ->
        {:ok, str_id} = Ecto.UUID.load(root_id)
        str_id

      _ ->
        conversation_id
    end
  end

  defp broadcast_graph_update(root_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "conversations:graph:#{root_id}",
      {:graph_updated}
    )
  end

  defp broadcast_sidebar_update(user_id) when is_binary(user_id) do
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
  # A caller-supplied name (test seams) is honored as before.
  defp mint_sprite_name(:runner, user_id, nil), do: Fountain.Runners.mint_sandbox_name(user_id)
  defp mint_sprite_name(_provider, _user_id, name) when is_binary(name), do: {:ok, name}

  defp mint_sprite_name(_provider, user_id, nil),
    do: {:ok, "fountain-#{tenant_prefix(user_id)}-#{short_id()}"}

  defp tenant_prefix(user_id) when is_binary(user_id), do: binary_part(user_id, 0, 8)

  # `parent_conversation_id` arrives from a client-supplied header
  # (X-Fountain-Parent-Conversation-Id). The changeset only enforced an FK, so
  # any conversation id in the system was accepted — including another tenant's,
  # which grafted this conversation onto their spawn tree and theirs onto ours.
  #
  # A legitimate spawn comes from inside a sprite holding that tenant's own
  # token, so ownership always matches; a mismatch is a bug or an attack.
  defp resolve_parent_id(nil, _user_id), do: {:ok, nil}
  defp resolve_parent_id("", _user_id), do: {:ok, nil}

  defp resolve_parent_id(id, user_id) when is_binary(id) and is_binary(user_id) do
    # A header that is not a uuid is not a conversation anyone owns.
    # `get_conversation/2` reads it as nil rather than raising (#1679), so this
    # stays the plain lookup it was.
    case get_conversation(id, user_id) do
      nil -> {:error, :parent_not_found}
      conv -> {:ok, conv.id}
    end
  end

  defp resolve_vault_id(nil, _user_id, _agent), do: {:ok, nil}
  defp resolve_vault_id("", _user_id, _agent), do: {:ok, nil}

  defp resolve_vault_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_vault_allowed(id, agent) do
      case Fountain.Vaults.get_vault(id, user_id) do
        nil -> {:error, :vault_not_found}
        vault -> {:ok, vault.id}
      end
    end
  end

  # Vault values win on env-var collision, so an attached vault overrides
  # the agent's reviewed environment. agent.allowed_vault_ids scopes who
  # may do that: nil keeps the legacy any-tenant-vault behavior, [] forbids
  # attaching any vault, a non-empty list is an allowlist.
  defp check_vault_allowed(_vault_id, %Agents.Agent{allowed_vault_ids: nil}), do: :ok

  defp check_vault_allowed(vault_id, %Agents.Agent{allowed_vault_ids: allowed}) do
    if vault_id in allowed, do: :ok, else: {:error, :vault_not_allowed}
  end

  # A per-launch environment override (#783): the conversation is provisioned
  # from this environment instead of the agent's own, and stays pinned to it
  # across wakes. Resolved exactly like the vault — a scoped fetch (a foreign
  # id reads as not found, so it cannot be probed) behind the agent's allowlist.
  defp resolve_environment_id(nil, _user_id, _agent), do: {:ok, nil}
  defp resolve_environment_id("", _user_id, _agent), do: {:ok, nil}

  defp resolve_environment_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_environment_allowed(id, agent) do
      case Fountain.Environments.get_environment(id, user_id) do
        nil -> {:error, :environment_not_found}
        env -> {:ok, env.id}
      end
    end
  end

  # An override replaces the reviewed environment wholesale, so it is scoped
  # the same way as a vault: nil = any tenant environment, [] = none, a
  # non-empty list is an allowlist. Default nil is deliberate — a caller who
  # can attach a vault can already override every key, so a stricter default
  # here would guard nothing (#783). Naming the agent's own environment is not
  # an override, so it passes regardless of the list.
  defp check_environment_allowed(_id, %Agents.Agent{allowed_environment_ids: nil}), do: :ok
  defp check_environment_allowed(id, %Agents.Agent{environment_id: id}), do: :ok

  defp check_environment_allowed(id, %Agents.Agent{allowed_environment_ids: allowed}) do
    if id in allowed, do: :ok, else: {:error, :environment_not_allowed}
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
  defp resolve_permission_policy(nil, _agent), do: {:ok, nil}
  defp resolve_permission_policy(policy, _agent) when policy == %{}, do: {:ok, nil}

  defp resolve_permission_policy(policy, agent) when is_map(policy) do
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

  defp resolve_permission_policy(_policy, _agent), do: {:error, :permission_policy_invalid}

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

  # `ask_timeout` is seconds, not a verdict (#1635).
  defp validate_reserved_keys(policy) do
    case Map.fetch(policy, "ask_timeout") do
      {:ok, value} ->
        if PermissionPolicy.valid_ask_timeout?(value),
          do: :ok,
          else: {:error, :permission_policy_invalid}

      :error ->
        :ok
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

  defp wake_conversation_for(conv_id, initial_prompt, purpose) do
    # Ownership is established by callers before reaching this internal wake
    # path. The agent fetched below is the conversation's own agent_id,
    # same tenant by construction.
    with :ok <- require_provider_commit_boundary(),
         %Conversation{} = conv <- _unsafe_get_conversation(conv_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         # Preflight only: no database lock spans provider I/O. Turn admission
         # checks again under its transaction. Cancellation must remain reachable.
         :ok <-
           if(purpose == :interrupt,
             do: :ok,
             else: _unsafe_check_saved_execution_allowance(conv.id)
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
               # Whose inference key would run this (#1388): refused only when it
               # would be Fountain's and the deployment has spent its day. A door
               # with no platform key configured runs no query here.
               :ok <-
                 Fountain.PlatformInference.gate(
                   conv.user_id,
                   agent.model,
                   conv.runtime
                 ),
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

                {:ok, _unsafe_get_conversation!(conv.id)}

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

              {:ok, _unsafe_get_conversation!(conv.id)}

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

  @doc """
  Reach a conversation whose `ConversationServer` is gone, so a caller can
  interrupt the turn it left behind.

  A missing server does not mean there is nothing to interrupt: the process
  can have exited (deploy, Horde rebalance, a plain `{:stop, :normal, _}`)
  while a turn was still marked `running`. Waking reattaches to a live sprite
  session if one exists, or reconciles the orphaned turn itself when none
  does. Only a row that says `running` is worth a wake — an idle, terminated
  or unknown conversation has nothing running regardless, and must not pay
  for one it does not need.

  The two misses are different answers, and #1179 is what conflating them
  looked like from a client. `:not_found` is no such conversation row.
  `:not_running` is a row that exists in no state to be interrupted. Only the
  first is a 404, because every caller establishes ownership before reaching
  here, so answering "wrong id, or it belongs to another account" for a
  conversation the same key can `GET` is a lie.
  """
  @spec wake_for_interrupt(binary()) :: {:ok, pid()} | {:error, :not_found | :not_running}
  def wake_for_interrupt(conv_id) when is_binary(conv_id) do
    case _unsafe_get_conversation(conv_id) do
      nil ->
        {:error, :not_found}

      %Conversation{status: "running"} ->
        with {:ok, conv} <- wake_conversation_for(conv_id, nil, :interrupt),
             pid when is_pid(pid) <- ConversationServer.whereis(conv.id) do
          {:ok, pid}
        else
          _ -> {:error, :not_running}
        end

      _ ->
        {:error, :not_running}
    end
  end

  # Probe the existing sandbox: if it's `ready` or `suspended` and sprites.dev
  # confirms the sprite still exists, we can reattach without provisioning a
  # new one. Otherwise, fall through to creating a fresh sandbox.
  defp maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  defp maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case _unsafe_get_sandbox(sandbox_id) do
      %Sandbox{reset_requested_at: at, status: status}
      when not is_nil(at) and status not in ["terminated", "failed"] ->
        {:error, :sandbox_reset_pending}

      %{status: status, sprite_name: name} = sandbox
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
  defp probe_reusable_sandbox(%{status: status, sprite_name: name} = sandbox, sandbox_id) do
    provider = sandbox_provider_atom(sandbox)

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

  defp probe_sandbox(provider, name, status, sandbox_id) do
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

  def sandbox_provider_atom(%{provider: provider}) when is_binary(provider),
    do: String.to_existing_atom(provider)

  def sandbox_provider_atom(_sandbox), do: :sprites

  # Placement for a NEW sandbox: the agent's override, else the instance
  # default. Only an override is gated on enabledness — the default keeps its
  # lazy credential check (a credential-less boot fails at provision time
  # with the missing variable named, exactly as before), while an agent
  # pinned to a provider whose credentials were since removed fails here
  # with an error the API/UI can explain.
  defp resolve_sandbox_provider(%Agents.Agent{sandbox_provider: nil}),
    do: {:ok, Fountain.SandboxProviders.default_provider()}

  defp resolve_sandbox_provider(%Agents.Agent{sandbox_provider: value}) do
    provider = String.to_existing_atom(value)

    if Fountain.SandboxProviders.enabled?(provider) do
      {:ok, provider}
    else
      {:error, {:sandbox_provider_disabled, provider}}
    end
  end

  # Waking a suspended sandbox turns a parked sprite back into compute, so it
  # re-runs the quota gate — under the same advisory lock as creation, with the
  # row re-read inside. Two concurrent wakes both probe `suspended`; the loser
  # re-reads the winner's `ready` flip and must not double-stamp the clock.
  # `exclude: sandbox_id` makes the check identical for both ("does the user
  # have capacity besides this sandbox"), so the loser is never spuriously
  # refused at the cap for a wake that added no concurrency.
  defp wake_suspended_sandbox(user_id, sandbox_id) do
    case _unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: "suspended"} ->
        Fountain.Quotas.with_sandbox_reservation(user_id, [exclude: sandbox_id], fn ->
          case _unsafe_get_sandbox(sandbox_id) do
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
  defp resume_and_wake(sandbox) do
    handle =
      Managoat.Sandbox.build_handle(sandbox_provider_atom(sandbox), sandbox.sprite_name)

    case Managoat.Sandbox.resume(handle) do
      {:ok, _handle} ->
        update_sandbox(sandbox, %{
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
  defp start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
    with {:ok, pid} <-
           Horde.DynamicSupervisor.start_child(
             Fountain.ConversationSupervisor,
             {ConversationServer,
              [
                conversation_id: conv.id,
                sandbox_id: sandbox_id,
                runtime_module: runtime_module
              ]}
           ) do
      if is_binary(initial_prompt) and initial_prompt != "" do
        ConversationServer.queue_initial_prompt(pid, initial_prompt)
      end

      {:ok, _unsafe_get_conversation!(conv.id)}
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
    old = if conv.sandbox_id, do: _unsafe_get_sandbox(conv.sandbox_id)
    mode = (old && old.mode) || "ephemeral"
    if mode == "persistent", do: _ = mark_old_sandbox_terminated(conv.sandbox_id)

    with :ok <- Fountain.Accounts.check_not_suspended(conv.user_id),
         :ok <- Fountain.Billing.check_spend(conv.user_id),
         # Whose inference key would run this (#1388): refused only when it
         # would be Fountain's and the deployment has spent its day. A door
         # with no platform key configured runs no query here.
         :ok <-
           Fountain.PlatformInference.gate(
             conv.user_id,
             agent.model,
             conv.runtime
           ),
         # A fresh sandbox is a fresh placement decision — re-resolve from
         # the agent, so a conversation whose old sandbox died can migrate
         # providers naturally.
         {:ok, provider} <- resolve_sandbox_provider(agent),
         {:ok, sprite_name} <- mint_sprite_name(provider, conv.user_id, nil),
         # Same reservation as start_conversation/1 — see the note there (#330).
         {:ok, new_sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(
             conv.user_id,
             [exclude: conv.sandbox_id],
             fn ->
               create_sandbox(%{
                 environment_id: conv.environment_id || agent.environment_id,
                 agent_id: conv.agent_id,
                 vault_id: conv.vault_id,
                 mode: mode,
                 sprite_name: sprite_name,
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
            update_conversation(conv, %{sandbox_id: new_sandbox.id, status: "pending"})

          # The machine was gone for everyone on it, not just the conversation
          # that noticed (ADR 0023 gate 5).
          move_cotenants(old_sandbox_id, new_sandbox, conv.id)

          {:ok, _unsafe_get_conversation!(conv.id)}

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

          {:ok, _unsafe_get_conversation!(conv.id)}

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
  defp move_cotenants(nil, _new_sandbox, _conv_id), do: :ok

  defp move_cotenants(old_sandbox_id, %Sandbox{} = new_sandbox, conv_id)
       when is_binary(old_sandbox_id) do
    case _unsafe_list_cotenants_with_identity(old_sandbox_id, conv_id) do
      [] ->
        :ok

      cotenants ->
        identity = {new_sandbox.environment_id, new_sandbox.vault_id}

        {following, on_their_own} =
          Enum.split_with(cotenants, fn {_id, env_id, vault_id} ->
            {env_id, vault_id} == identity
          end)

        follow_cotenants(Enum.map(following, &elem(&1, 0)), new_sandbox.id)
        strand_cotenants(Enum.map(on_their_own, &elem(&1, 0)))
        :ok
    end
  end

  defp follow_cotenants([], _new_sandbox_id), do: :ok

  defp follow_cotenants(ids, new_sandbox_id) do
    message =
      "The sandbox this conversation was on is gone; it moved to a fresh one together " <>
        "with the conversations that shared it. The transcript is kept, but the agent " <>
        "starts a new session and will not remember the earlier turns."

    tell_cotenants(ids, "replaced", message)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(c in Conversation, where: c.id in ^ids),
      set: [sandbox_id: new_sandbox_id, runtime_session_id: nil, updated_at: now]
    )

    Enum.each(ids, fn id ->
      publish_stage(id, "sandbox", "done", %{
        event: "replaced",
        reason: "sprite_gone",
        sandbox_id: new_sandbox_id,
        message: message
      })
    end)
  end

  defp strand_cotenants([]), do: :ok

  defp strand_cotenants(ids) do
    message =
      "The sandbox this conversation was on is gone. It named a different environment " <>
        "or vault from the conversation that replaced the machine, so it did not follow " <>
        "onto that one; its next prompt builds a machine from what it declares. The " <>
        "transcript is kept, and the agent starts a new session."

    tell_cotenants(ids, "reset", message)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # `sandbox_id` is left naming the retired row on purpose: `wake_conversation/2`
    # reads a terminated row as `:create_new` and provisions from this
    # conversation's own environment and vault.
    Repo.update_all(from(c in Conversation, where: c.id in ^ids),
      set: [runtime_session_id: nil, updated_at: now]
    )

    Enum.each(ids, fn id ->
      publish_stage(id, "sandbox", "done", %{
        event: "reset",
        reason: "sprite_gone",
        message: message
      })
    end)
  end

  defp tell_cotenants(ids, event, message) do
    Enum.each(ids, fn id ->
      case ConversationServer.whereis(id) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:machine_gone, event, "sprite_gone", message})
      end
    end)
  end

  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    case _unsafe_get_sandbox(sandbox_id) do
      nil ->
        :ok

      sb when sb.status in ["terminated", "failed"] ->
        :ok

      sb ->
        update_sandbox(sb, %{
          status: "terminated",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end
end
