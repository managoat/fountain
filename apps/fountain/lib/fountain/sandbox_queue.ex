defmodule Fountain.SandboxQueue do
  @moduledoc """
  The bounded per-tenant queue for sandbox capacity (#1033, ADR 0042).

  A start reaches a capacity limit two ways: the tenant's own cap, funded by
  its credit balance under ADR 0031, and `SANDBOX_FLEET_CEILING` across the
  whole deployment. `Quotas.with_sandbox_reservation/3` refuses both
  immediately, which is the right answer for a caller that can retry and the
  wrong one for a cron firing with nobody there to retry it.

  This module holds that work instead. It never raises a limit: the queue
  delays admission and every replay re-enters the same reservation, the same
  credit gate and the same platform-inference gate.

  Bounded twice. A tenant holds at most `SANDBOX_QUEUE_MAX_DEPTH` active
  requests, and a request waits at most `SANDBOX_QUEUE_MAX_WAIT_SECONDS`.
  Beyond the depth bound the caller keeps its immediate capacity error.

  ## Claiming

  Several replicas can be told a slot freed at the same instant, so a drain
  claims before it replays. Every write that moves a row out of a live status
  is a compare-and-swap fenced on the `(status, updated_at)` the drain
  observed, and a claim is the same compare-and-swap: `claim_next/2` will take
  a `queued` row, or a `starting` row whose claim outran
  `@claim_timeout_seconds` because the worker holding it died. Only the
  replica that won the swap can write that row's outcome, so a zombie replay
  cannot overwrite the row a recovering drain has since taken.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Audit
  alias Fountain.Conversations.{ConversationServer, Launch, PromptDelivery}
  alias Fountain.Repo
  alias Fountain.SandboxQueue.Request

  @default_max_depth 10
  @default_max_wait_seconds 3600

  # One source of truth. `Request.active_statuses/0` is what the ops gauge
  # reads too, and two copies would let the depth bound and the gauge disagree
  # silently if a status were ever added.
  @active_statuses Request.active_statuses()

  # A worker can die after its compare-and-swap and before its replay
  # finishes. Both replay paths normally return in milliseconds — provisioning
  # happens in the ConversationServer, not under the claim — so five minutes
  # identifies an abandoned claim with a wide margin.
  @claim_timeout_seconds 300

  # Not this request's fault and not this tenant's ceiling: the turn in flight
  # ends, the home sandbox finishes provisioning, the runner comes back, the
  # machine's owner finishes the operation it is in the middle of. The request
  # goes back in line rather than burning its prompt on a condition that clears
  # by itself. `Fountain.Workers.TeamScheduleRun` reads this list, for exactly
  # this reason.
  #
  # `sandbox_unavailable` is ADR 0058's refusal, added in stage 6a: a wake or
  # an attach onto a machine its owner is parking, destroying or rebuilding.
  # It is the shortest-lived of these — one provider round trip — and it was
  # the one missing, which is how a queued start could be failed by a condition
  # that had already cleared.
  @transient_errors ~w(busy provisioning runner_offline sandbox_at_capacity sandbox_unavailable
                       sprite_probe_failed sandbox_resume_failed)a

  # Every replay and every terminal write the drain makes is attributed to the
  # queue, not to whoever originally asked. The audit vocabulary is closed
  # (ADR 0013) and `system:<worker>` is the shape a background caller takes.
  @system_actor "system:sandbox_queue"

  @doc """
  The audit actor a replay runs as.

  Exposed the way `Team.Schedules.actor/0` is, so a surface can tell the
  drainer's replay from a person's own call without hardcoding the string.
  """
  def actor, do: @system_actor

  @doc """
  The retryable reasons this queue snoozes on rather than treats as terminal.

  **One definition.** `Fountain.Workers.TeamScheduleRun` reads its own snooze
  guard from this at compile time (`@transient_errors
  SandboxQueue.transient_errors()`) rather than keeping a second list. It kept
  one, spelled out inline, until ADR 0058 stage 6a. The two agreed on the day
  6a read them and would have drifted that same day: adding
  `sandbox_unavailable` here without going and finding the other copy leaves a
  schedule firing at a machine mid-operation consumed rather than retried,
  which is the shape #2286's fourth review round caught on the previous
  spelling of this refusal.
  """
  @spec transient_errors() :: [atom()]
  def transient_errors, do: @transient_errors

  # Its own advisory-lock namespace. The depth bound counts rows in
  # `sandbox_requests` and has nothing to serialize against a sandbox
  # reservation, and every namespace here hashes a different kind of id into
  # the same 32 bits: sharing one would let a `phash2` collision between a
  # user and a sandbox block an unrelated writer. Taken: 4315
  # `Fountain.Quotas`, 4316 `Conversations`, 4331 `Fountain.Connections`.
  @lock_namespace 4317

  @doc """
  Queue a start or a scheduled run, subject to the per-tenant depth bound.

  `params` is a map the caller builds key by key — never a request body cast
  wholesale. Returns `{:error, :queue_full}` at the depth bound, which the
  caller turns back into the capacity error it was about to send.

  A `schedule_run` is deduplicated against the schedule's own live request, so
  a cron that keeps firing while the first one waits does not stack ten copies
  of the same run. That dedup wins over the depth bound: it removes a row
  rather than adding one.
  """
  def enqueue(params, opts \\ []) do
    with {:ok, outcome} <- insert_bounded(params) do
      case outcome do
        # The schedule already had a live request. Nothing was written, so
        # nothing is recorded: a trail that logs an attempt as a change is
        # worse than no trail (ADR 0013).
        {:deduplicated, request} ->
          {:ok, request}

        # Audited outside the transaction: `Audit.record/1` is best-effort
        # by rescuing, and a rescue does not survive a transaction — a
        # failed audit insert would abort the enclosing one and take the
        # request with it.
        {:inserted, request} ->
          audited(request, "sandbox_request.enqueued", opts)
          emit_depth(request.user_id)
          {:ok, request}
      end
    end
  end

  @doc """
  The tenant's live request for a schedule, if it has one.

  What lets a surface say "waiting for a free slot" rather than repeating the
  capacity error a replay just met again.
  """
  def schedule_request(user_id, schedule_id)
      when is_binary(user_id) and is_binary(schedule_id) do
    existing_schedule_request(%{user_id: user_id, schedule_id: schedule_id})
  end

  # The depth bound is a check followed by an insert, so it needs the same
  # protection `Quotas.with_sandbox_reservation/3` gives the sandbox cap: two
  # requests that both read "room for one more" at the last slot is precisely
  # how #330 got past that cap before its advisory lock existed.
  #
  # The schedule dedup reads under the same lock, for the same reason: two
  # firings of one schedule that both read "no live request" would both insert,
  # which is the stacking the dedup exists to prevent.
  defp insert_bounded(params) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @lock_namespace,
        :erlang.phash2(params.user_id)
      ])

      case existing_schedule_request(params) do
        %Request{} = request ->
          {:deduplicated, request}

        nil ->
          with :ok <- check_depth(params.user_id),
               {:ok, request} <-
                 %Request{}
                 |> Request.changeset(Map.put_new(params, :status, "queued"))
                 |> Repo.insert() do
            {:inserted, request}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @doc "List a tenant's waiting requests, oldest first."
  def list_queued(user_id) when is_binary(user_id), do: Repo.all(queued_query(user_id))

  @doc "Get a request scoped to its tenant."
  def get_request(id, user_id) when is_binary(id) and is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, request_id} -> Repo.get_by(Request, id: request_id, user_id: user_id)
      :error -> nil
    end
  end

  @doc """
  A waiting request's one-based position.

  Counts claimed (`starting`) rows as well as waiting ones: a request being
  replayed right now is still ahead of this one, and leaving it out reports
  `position: 1` to a caller that has someone in front of it. `nil` once the
  request is no longer waiting.
  """
  def position(%Request{status: "queued"} = request) do
    Repo.aggregate(
      from(r in Request,
        where:
          r.user_id == ^request.user_id and r.status in ^@active_statuses and
            (r.inserted_at < ^request.inserted_at or
               (r.inserted_at == ^request.inserted_at and r.id < ^request.id))
      ),
      :count
    ) + 1
  end

  def position(%Request{}), do: nil

  @doc """
  Cancel a request if it is still waiting.

  A compare-and-swap, not a read-then-write: the drainer may have claimed the
  row between the caller's fetch and this call, and a cancellation that
  reached a `starting` row would abandon a start already in flight.
  """
  def cancel_request(%Request{} = request, opts \\ []) do
    case swap(request.id, "queued", %{status: "cancelled", attrs: %{}}) do
      {:ok, cancelled} ->
        audited(cancelled, "sandbox_request.cancelled", opts)
        note_schedule_outcome(cancelled)
        emit_depth(cancelled.user_id)
        {:ok, cancelled}

      :stale ->
        {:error, :not_found}
    end
  end

  @doc """
  Expire overdue work, then drain one tenant in FIFO claim order.

  Returns `%{started:, failed:, expired:}`. Safe to run concurrently with
  another drain of the same tenant: every row it touches is claimed first.
  """
  def drain(user_id) when is_binary(user_id) do
    expired = expire_overdue(user_id)
    {started, failed} = drain_loop(user_id, {0, 0})
    emit_depth(user_id)
    %{started: started, failed: failed, expired: expired}
  end

  @doc """
  Whether any tenant has work waiting or claimed.

  An existence probe against the partial index, for the choke point that has
  to decide whether a freed slot is worth a job at all. Cheaper than
  `user_ids_with_active_requests/0`, which scans for the distinct set.
  """
  def any_active_requests? do
    Repo.exists?(from r in Request, where: r.status in ^@active_statuses)
  end

  @doc "Tenant ids with work waiting or currently claimed."
  def user_ids_with_active_requests do
    Repo.all(
      from r in Request,
        where: r.status in ^@active_statuses,
        distinct: true,
        select: r.user_id
    )
  end

  # `skipped` holds the requests this pass released for a transient reason.
  # Without it the loop would re-claim the row it just put back and spin.
  defp drain_loop(user_id, counts, skipped \\ [])

  defp drain_loop(user_id, {started, failed} = counts, skipped) do
    case claim_next(user_id, skipped) do
      nil ->
        counts

      {request, fence} ->
        case attempt(request) do
          {:ok, conversation_id} ->
            finish(request, fence, %{status: "started", conversation_id: conversation_id})
            drain_loop(user_id, {started + 1, failed}, skipped)

          # Capacity did not free after all. Every request behind this one
          # would meet the same wall, so stop the pass entirely rather than
          # walk the whole queue into the same refusal.
          {:error, {:sandbox_quota_exceeded, _}} ->
            release(request, fence)
            counts

          {:error, :fleet_full} ->
            release(request, fence)
            counts

          # Transient and specific to this request's teammate rather than to
          # the tenant, so the rest of the queue can still make progress.
          {:error, reason} when reason in @transient_errors ->
            release(request, fence)
            drain_loop(user_id, counts, [request.id | skipped])

          {:error, {:prompt_delivery_unknown, conversation_id}} ->
            finish(request, fence, %{
              status: "failed",
              error: "prompt_delivery_unknown",
              conversation_id: conversation_id
            })

            drain_loop(user_id, {started, failed + 1}, skipped)

          {:error, reason} ->
            finish(request, fence, %{status: "failed", error: describe(reason)})
            drain_loop(user_id, {started, failed + 1}, skipped)
        end
    end
  end

  # The claim. Takes the oldest waiting row, or the oldest abandoned claim,
  # and swaps it to `starting` fenced on the exact `(status, updated_at)` this
  # read observed. Losing the swap means another replica got there first, so
  # go round again rather than replaying a row somebody else owns.
  defp claim_next(user_id, skipped) do
    cutoff = DateTime.add(DateTime.utc_now(), -@claim_timeout_seconds, :second)

    query =
      from r in Request,
        where:
          r.user_id == ^user_id and r.id not in ^skipped and
            (r.status == "queued" or (r.status == "starting" and r.updated_at < ^cutoff)),
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: 1

    case Repo.one(query) do
      nil ->
        nil

      request ->
        case swap_fenced(request, %{status: "starting"}) do
          {:ok, claimed} ->
            if request.status == "starting" do
              Logger.info(
                "sandbox queue: recovered request #{claimed.id} from an abandoned claim"
              )
            end

            {claimed, claimed.updated_at}

          # Another replica got there first. Skipping the row we lost makes
          # termination structural — each turn round either claims a row or
          # removes a candidate — rather than resting on the row no longer
          # matching the query. A row that is claimed and released inside this
          # pass simply waits for the next one.
          :stale ->
            claim_next(user_id, [request.id | skipped])
        end
    end
  end

  # Back in line, under the same fence. A lost swap means a recovering drain
  # already took the claim: there is nothing left to release, and raising here
  # would fail the job and strand every other request this tenant has waiting.
  defp release(%Request{} = request, fence) do
    case swap_fenced(%{request | status: "starting", updated_at: fence}, %{status: "queued"}) do
      {:ok, _} ->
        :ok

      :stale ->
        Logger.info("sandbox queue: request #{request.id} was no longer claimed on release")
        :ok
    end
  end

  # The terminal write, under the same fence for the same reason. A blind
  # update here is the double-start hole: a replay slow enough to lose its
  # claim would overwrite the row a recovering drain had already replayed.
  defp finish(%Request{} = request, fence, attrs) do
    case swap_fenced(
           %{request | status: "starting", updated_at: fence},
           Map.put(attrs, :attrs, %{})
         ) do
      {:ok, updated} ->
        # The status names its own event. A `case` over today's two outcomes
        # would be a `CaseClauseError` raised inside the pass the moment a
        # third one is written through here, and it would strand every other
        # request this tenant has waiting.
        audited(updated, "sandbox_request.#{updated.status}", actor: @system_actor)
        emit_completed(updated, request.inserted_at)
        :ok

      :stale ->
        Logger.warning(
          "sandbox queue: request #{request.id} lost its claim mid-replay; outcome not recorded"
        )

        :ok
    end
  end

  defp attempt(%Request{kind: "start"} = request) do
    attrs =
      request.attrs
      |> Map.put("user_id", request.user_id)
      |> Map.put("agent_id", request.agent_id)
      |> put_unless_nil("source", request.source)

    opts = replay_opts(request)

    with {:ok, conversation, outcome} <- Launch.start_or_resume_conversation(attrs, opts),
         :ok <- deliver_resumed_prompt(conversation, outcome, attrs, opts) do
      {:ok, conversation.id}
    end
  end

  defp attempt(%Request{kind: "schedule_run", schedule_id: schedule_id} = request) do
    case Fountain.Team.Schedules.get_schedule(schedule_id, request.user_id) do
      nil ->
        {:error, :schedule_deleted}

      schedule ->
        with {:ok, conversation} <-
               Fountain.Team.Schedules.run_schedule(schedule, actor: @system_actor) do
          {:ok, conversation.id}
        end
    end
  end

  # A launch policy belongs to the conversation created for it. Prompt
  # delivery has no per-turn override, and checking a resumed row's current
  # policy would not bind the later turn's policy. Refuse any nonempty launch
  # override before sending; fresh replay goes through normal launch admission.
  defp deliver_resumed_prompt(
         _conversation,
         :resumed,
         %{"prompt" => prompt, "permission_policy" => policy},
         _opts
       )
       when is_binary(prompt) and prompt != "" and policy not in [nil, %{}],
       do: {:error, :permission_policy_requires_fresh_conversation}

  # A live client sends its prompt separately after a channel resume. A queue
  # replay has no client, so it must deliver before reporting started. Let
  # definite refusals reach the drain's retry/terminal handling. A timeout or
  # distribution loss can follow acceptance, so record uncertainty and its
  # conversation for inspection instead of automatically sending it again.
  defp deliver_resumed_prompt(conversation, :resumed, %{"prompt" => prompt} = attrs, opts)
       when is_binary(prompt) and prompt != "" do
    opts =
      [uncertain_error: :prompt_delivery_unknown] ++ PromptDelivery.from_request(attrs) ++ opts

    case ConversationServer.send_prompt(conversation.id, prompt, attrs["images"] || [], opts) do
      {:error, :prompt_delivery_unknown} -> {:error, {:prompt_delivery_unknown, conversation.id}}
      result -> result
    end
  end

  defp deliver_resumed_prompt(_conversation, _outcome, _attrs, _opts), do: :ok

  # What the door passed, minus what only a live request has. `source` is the
  # provenance the API inferred from the parent-conversation header, so a
  # queued fan-out has to replay as `agent` rather than default to `api`;
  # `sandbox_key_id` is the ADR 0045 restriction, and dropping it would let a
  # `sprite` token relabel a conversation it does not own by way of a
  # `channel_id` resume the replay reaches an hour later. `request_ip` is
  # deliberately absent: there is no request.
  defp replay_opts(%Request{sandbox_key_id: nil}), do: [actor: @system_actor]

  defp replay_opts(%Request{sandbox_key_id: key_id}),
    do: [actor: @system_actor, sandbox_key_id: key_id]

  defp put_unless_nil(attrs, _key, nil), do: attrs
  defp put_unless_nil(attrs, key, value), do: Map.put(attrs, key, value)

  # A `schedule_run` that ended without running has to tell its schedule, or
  # that row keeps reporting a wait that is over. `started` and `failed` went
  # through `run_schedule/2`, which wrote the row itself; `expired` and
  # `cancelled` never reach it.
  defp note_schedule_outcome(%Request{kind: "schedule_run", schedule_id: id} = request)
       when is_binary(id) do
    Fountain.Team.Schedules.note_queued_run_ended(id, request.user_id, request.status)
  end

  defp note_schedule_outcome(%Request{}), do: :ok

  defp expire_overdue(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_wait_seconds(), :second)

    overdue =
      Repo.all(
        from r in Request,
          where: r.user_id == ^user_id and r.status == "queued" and r.inserted_at < ^cutoff
      )

    Enum.count(overdue, fn request ->
      case swap(request.id, "queued", %{status: "expired", attrs: %{}}) do
        {:ok, expired} ->
          audited(expired, "sandbox_request.expired", actor: @system_actor)
          note_schedule_outcome(expired)
          emit_completed(expired, request.inserted_at)
          true

        :stale ->
          false
      end
    end)
  end

  # One compare-and-swap on status alone, for the transitions a caller makes
  # from outside a claim. Returns the row it wrote, or `:stale` when somebody
  # else moved it first. No path in this module writes a status with a blind
  # `Repo.update/1`.
  defp swap(id, expected_status, attrs) do
    sets = attrs |> Map.to_list() |> Keyword.put(:updated_at, DateTime.utc_now())

    case Repo.update_all(
           from(r in Request, where: r.id == ^id and r.status == ^expected_status),
           set: sets
         ) do
      {1, _} -> {:ok, Repo.get!(Request, id)}
      {0, _} -> :stale
    end
  end

  # The same swap, fenced on the exact version observed. `updated_at` is
  # microsecond-resolution and every write here changes it, so the pair is a
  # version token: a writer holding an older one has been overtaken.
  defp swap_fenced(observed, attrs) do
    sets = attrs |> Map.to_list() |> Keyword.put(:updated_at, DateTime.utc_now())

    case Repo.update_all(
           from(r in Request,
             where:
               r.id == ^observed.id and r.status == ^observed.status and
                 r.updated_at == ^observed.updated_at
           ),
           set: sets
         ) do
      {1, _} -> {:ok, Repo.get!(Request, observed.id)}
      {0, _} -> :stale
    end
  end

  defp queued_query(user_id) do
    from r in Request,
      where: r.user_id == ^user_id and r.status == "queued",
      order_by: [asc: r.inserted_at, asc: r.id]
  end

  defp check_depth(user_id) do
    if active_depth(user_id) < max_depth(), do: :ok, else: {:error, :queue_full}
  end

  defp active_depth(user_id) do
    Repo.aggregate(
      from(r in Request, where: r.user_id == ^user_id and r.status in ^@active_statuses),
      :count
    )
  end

  defp existing_schedule_request(%{schedule_id: schedule_id, user_id: user_id})
       when is_binary(schedule_id) do
    Repo.one(
      from r in Request,
        where:
          r.user_id == ^user_id and r.schedule_id == ^schedule_id and
            r.status in ^@active_statuses,
        limit: 1
    )
  end

  defp existing_schedule_request(_params), do: nil

  defp emit_completed(%Request{} = request, waiting_since) do
    :telemetry.execute(
      [:fountain, :sandbox_queue, :completed],
      %{
        wait_ms: DateTime.diff(DateTime.utc_now(), waiting_since, :millisecond),
        count: 1
      },
      %{status: request.status, kind: request.kind}
    )
  end

  defp describe({:sandbox_quota_exceeded, %{count: count, limit: limit}}),
    do: "sandbox quota: #{count}/#{limit}"

  defp describe(%Ecto.Changeset{}), do: "invalid conversation attrs"
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(reason), do: inspect(reason) |> String.slice(0, 250)

  defp emit_depth(user_id) do
    :telemetry.execute(
      [:fountain, :sandbox_queue, :tenant_depth],
      %{depth: active_depth(user_id)},
      %{}
    )
  end

  # Keys, sizes and provenance — never the prompt, which lives in `attrs` and
  # is erased at every terminal transition anyway.
  defp audited(%Request{} = request, action, opts) do
    Audit.record(%{
      user_id: request.user_id,
      action: action,
      resource_type: "sandbox_request",
      resource_id: request.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "kind" => request.kind,
        "agent_id" => request.agent_id,
        "schedule_id" => request.schedule_id,
        "conversation_id" => request.conversation_id,
        "error" => request.error
      }
    })

    request
  end

  defp max_depth,
    do: Application.get_env(:fountain, :sandbox_queue_max_depth, @default_max_depth)

  defp max_wait_seconds,
    do:
      Application.get_env(
        :fountain,
        :sandbox_queue_max_wait_seconds,
        @default_max_wait_seconds
      )
end
