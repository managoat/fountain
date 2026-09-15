defmodule Fountain.Workers.SandboxReaper do
  @moduledoc """
  Reconciles the `sandboxes` table against what actually exists at sprites.dev.

  ## What leaks, and how

  Both destroy call sites in `ConversationServer` discard the result —
  `_ = Managoat.Sandbox.destroy(handle)` — and then mark the row `terminated` or
  `failed` regardless. So any destroy that fails for a transient reason leaves a
  sprite alive with a database row that says it is gone, and nothing ever looks
  again. This does not need a hard BEAM crash; the ordinary path is enough.

  Measured against production when this was written: 114 sprites existed at
  sprites.dev, 7 of them with a terminal sandbox row. The rest of the drift is
  historical (102 sprites with no row at all, from the pre-rename `aod-*` era)
  and 443 rows whose sprite is already gone.

  The other half is quota. `Fountain.Quotas` counts `pending`, `starting` and
  `ready` toward a tenant's concurrent-sandbox cap, deliberately — a sprite
  bills from the moment provisioning starts. A row stuck in `pending` because
  the BEAM died mid-provision therefore consumes cap forever, and a
  default-limit tenant with a few of those cannot start a conversation at all,
  with no self-serve way out.

  ## Three passes, in descending order of confidence

  1. **Release stuck rows.** `pending`/`starting` past the grace period with no
     live `ConversationServer` become `failed`. This frees quota and is safe:
     the row already cannot be used for anything. Two siblings run with it:
     `ready` rows past a lifetime bound are parked or expired, and rows whose
     teardown fence committed but whose terminal write never landed are
     finished.

  2. **Destroy sprites we know are dead.** A sandbox row in a terminal state
     whose sprite still exists at sprites.dev. Unambiguously ours,
     unambiguously finished.

  3. **Count sprites we do not recognise, and touch nothing.** Reported as a
     log line and a telemetry measurement.

  Pass 3 is deliberately inert. A sprite with no row is not proof of a leak: the
  same `SPRITES_TOKEN` may be in a developer's shell or a staging instance, and
  a sprite created seconds ago may simply not have committed its row yet.
  Production currently holds a `jake-*` sprite that is exactly this case.
  Destroying by absence-of-evidence would eventually delete someone's live work,
  and unlike a missed sprite that mistake cannot be undone. Cleaning up the
  legacy `aod-*` sprites is a one-off an operator can do by hand, having looked
  at the list.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Lifecycle, Sandbox, Turn}
  alias Fountain.Repo

  # Long enough to clear the slowest legitimate provision: package installs get
  # 300s per command and a clone gets 600s, and several can run in sequence.
  # Being late to release a stuck row costs a little quota; being early kills a
  # sandbox that was still starting.
  @stuck_after_minutes 60

  # A cap per run, so a large backlog drains over several hours instead of
  # firing hundreds of destroy calls at sprites.dev in one burst.
  @destroy_limit 25

  @terminal_statuses ~w(terminated failed)
  @active_statuses ~w(pending starting)

  @impl Oban.Worker
  def perform(_job) do
    released = release_stuck_sandboxes()
    {parked, expired} = sweep_abandoned_sandboxes()
    reconciled = sweep_fenced_teardowns()

    listings = list_by_provider()
    ok_listings = for {p, {:ok, names}} <- listings, into: %{}, do: {p, names}
    destroyed = destroy_dead_sprites(ok_listings)
    untracked = report_untracked(ok_listings)

    live = ok_listings |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum()

    Logger.info(
      "reaper: released=#{released} parked=#{parked} expired=#{expired} " <>
        "reconciled=#{reconciled} destroyed=#{destroyed} untracked=#{untracked} live=#{live}"
    )

    result =
      case for {p, {:error, reason}} <- listings, do: {p, reason} do
        [] ->
          :ok

        [{provider, reason} | _] = failures ->
          # Every pass that could run already did — per-provider isolation
          # means one backend's listing failure does not stop another's
          # destroys. Returning an error lets Oban retry the rest.
          Enum.each(failures, fn {p, r} ->
            Logger.warning("reaper: could not list #{p} sandboxes: #{inspect(r)}")
          end)

          _ = provider
          {:error, reason}
      end

    # `parked` is its own measurement: parks are reversible bookkeeping, and
    # folding them into `expired` would silently change what that metric means.
    # `reconciled` is its own for the opposite reason — it counts teardowns
    # that died halfway, so a non-zero value is a defect somewhere upstream,
    # not routine reclamation.
    :telemetry.execute(
      [:fountain, :reaper, :run],
      %{released: released, parked: parked, expired: expired, reconciled: reconciled},
      %{}
    )

    result
  end

  # ── pass 1: rows stuck mid-provision ──────────────────────────────────────

  @doc false
  def release_stuck_sandboxes do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stuck_after_minutes * 60, :second)

    Sandbox
    |> where(
      [s],
      s.status in ^@active_statuses and is_nil(s.reset_requested_at) and s.updated_at < ^cutoff
    )
    |> Repo.all()
    |> Repo.preload(:conversations)
    |> Enum.reject(&Lifecycle.any_server_alive?/1)
    |> Enum.map(fn sandbox ->
      was = sandbox.status

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: "failed",
          terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      Logger.info(
        "reaper: released stuck sandbox #{sandbox.id} (#{sandbox.machine_name}) " <>
          "after #{@stuck_after_minutes}m in #{sandbox.status}"
      )

      record_reap(sandbox, "sandbox.released_stuck", %{
        "previous_status" => was,
        "stuck_after_minutes" => @stuck_after_minutes
      })

      sandbox
    end)
    |> length()
  end

  # A live ConversationServer means provisioning is still in flight somewhere in
  # the cluster, however long it has taken. Horde's registry is cluster-wide, so
  # this is not just a local check — `Lifecycle.any_server_alive?/1` is the one
  # scan for it (#2255 decision 2), shared with `Termination.reap_sandbox/1`,
  # which used to scan for the same thing itself.
  # A sandbox the tenant did not stop, ending for a reason only the reaper
  # knows. Attributed to the worker so "my agent's sandbox vanished" has an
  # answer in the tenant's own trail rather than only in the server log —
  # `admin.sandbox.reaped` covered the admin-clicked path and nothing covered
  # this one (#551).
  defp record_reap(%Sandbox{} = sandbox, action, metadata) do
    Fountain.Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: "system:sandbox_reaper",
      metadata:
        metadata
        |> Map.put("sprite_name", sandbox.machine_name)
        |> Map.put("provider", sandbox.provider)
    })
  end

  # ── pass 1b: ready sandboxes nobody is holding ────────────────────────────

  # A `ready` row whose server died mid-wake looks identical to an abandoned
  # one until the new server registers in Horde — whose registry is an async
  # CRDT, so `Lifecycle.any_server_alive?/1` can briefly miss a live server on
  # another node. The wake path touches `updated_at` when it flips
  # `suspended → ready`, so a grace period on `updated_at` makes a just-woken
  # row untouchable for far longer than registry propagation takes.
  @abandoned_grace_minutes 15

  @doc """
  Sweeps `ready` sandboxes with no live server past a lifetime bound: past the
  idle bound they are parked to `suspended` (the sprite stays, scaled to zero,
  and the next prompt reattaches — decisions/0017); past the max-lifetime
  ceiling they are terminated, and pass 2 destroys the sprite this same run.

  This is the half of #167 that the ConversationServer cannot do. The server
  enforces its own bounds while it is alive, but a sandbox whose server
  died — a crash, a node that left the cluster, a deploy that happened to land
  between the rehydrator's scan and a reattach — has nothing watching it. The
  83-day-old sandbox in production was exactly that: `ready`, no server, alive
  since 2026-05-10.

  `suspended` rows deliberately match no pass: that is the durable resting
  state, aged out by nothing (decisions/0017).

  Activity includes turn insertion, start, completion and the last wake rather
  than `sandboxes.updated_at` or `conversations.updated_at`, both of which get
  touched by bookkeeping the user had nothing to do with — the rehydrator moves
  `conversations.updated_at` on every boot, which would make an abandoned
  conversation look freshly active after each deploy.

  Returns `{parked, expired}`.
  """
  def sweep_abandoned_sandboxes do
    idle = Lifecycle.idle_timeout_seconds()
    max_lifetime = Lifecycle.max_lifetime_seconds()

    if is_nil(idle) and is_nil(max_lifetime) do
      {0, 0}
    else
      now = DateTime.utc_now()
      grace_cutoff = DateTime.add(now, -@abandoned_grace_minutes * 60, :second)

      verdicts =
        Sandbox
        |> where(
          [s],
          s.status == "ready" and is_nil(s.reset_requested_at) and s.updated_at < ^grace_cutoff
        )
        |> Repo.all()
        |> Repo.preload(:conversations)
        |> Enum.reject(&Lifecycle.any_server_alive?/1)
        |> Enum.map(&{&1, check_bounds(&1, now)})

      {parked, expired} =
        Enum.reduce(verdicts, {0, 0}, fn
          {sandbox, {:expired, :idle}}, {p, e} ->
            case idle_sweep(sandbox) do
              :parked -> {p + 1, e}
              :expired -> {p, e + 1}
            end

          {sandbox, {:expired, :max_lifetime}}, {p, e} ->
            expire(sandbox, "past max lifetime")
            {p, e + 1}

          {_sandbox, :ok}, acc ->
            acc
        end)

      {parked, expired}
    end
  end

  # Same clock as ConversationServer.sandbox_clock_start/1: the max-lifetime
  # ceiling measures a continuous run, restarting on a wake from `suspended`.
  defp check_bounds(sandbox, now) do
    started_at = sandbox.last_resumed_at || sandbox.inserted_at
    Lifecycle.check(started_at, last_activity_at(sandbox), false, now)
  end

  # A queued or long-running turn can finish long after insertion. Waking
  # without a new turn is also activity; bookkeeping updates are not.
  defp last_activity_at(%Sandbox{} = sandbox) do
    %{inserted_at: inserted_at, last_resumed_at: resumed_at, conversations: convs} = sandbox
    conv_ids = Enum.map(convs, & &1.id)

    {inserted, started, ended} =
      Turn
      |> where([t], t.conversation_id in ^conv_ids)
      |> select([t], {max(t.inserted_at), max(t.started_at), max(t.ended_at)})
      |> Repo.one()

    [inserted_at, resumed_at, inserted, started, ended]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime)
  end

  # Idle with no server: park where the provider can preserve the disk,
  # expire where it cannot — the same Lifecycle.idle_action/1 decision the
  # ConversationServer applies, and the same degradation when the explicit
  # suspend call fails (an unparked sandbox keeps billing).
  defp idle_sweep(sandbox) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    with :suspend <- Lifecycle.idle_action(provider),
         :ok <-
           Managoat.Sandbox.suspend(Managoat.Sandbox.build_handle(provider, sandbox.machine_name)) do
      park(sandbox)
      :parked
    else
      :destroy ->
        expire(sandbox, "idle on a provider without suspend")
        :expired

      {:error, reason} ->
        Logger.warning(
          "reaper: suspend call failed for #{sandbox.machine_name} (#{inspect(reason)}); " <>
            "expiring instead"
        )

        expire(sandbox, "idle; suspend call failed")
        :expired
    end
  end

  # Reversible bookkeeping — the sandbox stays parked at the provider, and
  # the next prompt wakes it through the ordinary reattach path.
  defp park(sandbox) do
    # A home is checkpointed at its quietest moment, where the provider can
    # (ADR 0023, #1073); ephemeral sandboxes and failures skip straight on.
    Fountain.Conversations.HomeCheckpoint.on_park(sandbox)
    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "suspended"})

    Logger.info(
      "reaper: parked idle sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "ready with no live server past the idle bound"
    )

    record_reap(sandbox, "sandbox.suspended", %{"reason" => "idle with no live server"})

    sandbox
  end

  defp expire(sandbox, reason) do
    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{
        status: "terminated",
        terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Logger.info(
      "reaper: expired abandoned sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "ready with no live server, #{reason}"
    )

    record_reap(sandbox, "sandbox.expired", %{"reason" => reason})

    # The conversation is deliberately left alone. It stays resumable, and the
    # next prompt provisions a fresh sandbox (the runtime session on the
    # destroyed disk is lost — the price of the ceiling, see decisions/0017).
    # The sandbox itself is destroyed by pass 2 on this same run, now that the
    # row is terminal.
    sandbox
  end

  # ── pass 1c: teardown fences whose terminal write never landed ────────────

  # A teardown fence is committed in its own transaction, before any provider
  # I/O, and the terminal write lands after it (`Lifecycle.destroy/4`,
  # `Termination.retire_terminated_sandbox/2`, `Accounts.Deletion`). Anything
  # in between can lose: `Managoat.Sandbox.destroy/1` or `Egress.release/2`
  # raises, the retirement write is refused, the pod dies, an account deletion
  # halts mid-fence.
  #
  # What is left is a row with `teardown_requested_at` set and a live status,
  # and no pass here could see it. Both sweeps above require
  # `is_nil(reset_requested_at)`, which the fence always sets; pass 2 wants a
  # terminal status; pass 3 counts the sprite as known. Meanwhile
  # `Quotas.active_sandboxes/0` keeps counting the row against the tenant cap
  # and the fleet ceiling, and the sprite bills. The only exit was an operator
  # noticing and clicking Reap in /admin/sandboxes — and nothing surfaced the
  # row for them to notice (#2021 item 7). #1894 named this shape for the
  # *reset* fence and was answered by `SandboxResetReconciler` and the admin
  # retry; the teardown fence had no equivalent.
  #
  # Finishing the teardown is the only answer that respects the intent already
  # recorded and audited: the row goes terminal and pass 2 destroys the sprite
  # on this same run, exactly as `expire/2` relies on. This never *starts* a
  # teardown — `teardown_requested_at` is set by the fence alone, so a row only
  # reaches here because a caller already decided this machine was to go away.
  #
  # `reset_requested_at` on its own is deliberately not a predicate here: an
  # ordinary reset means "wipe and rebuild", not "terminate", and
  # `SandboxResetReconciler` already retries those.
  @fenced_teardown_grace_minutes 15

  @doc """
  Finishes teardowns that fenced and then died before the terminal write.

  A fenced row with a live status is invisible to every other pass and holds
  its quota slot forever, so this is the only thing that can free it. The grace
  period is measured from the fence, which is long enough that a teardown still
  in flight — including one walking a whole account's machines — is never
  swept, and the liveness check refuses a row some server still holds.

  Returns the number of rows terminated.
  """
  def sweep_fenced_teardowns do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@fenced_teardown_grace_minutes * 60, :second)

    Sandbox
    |> where(
      [s],
      not is_nil(s.teardown_requested_at) and s.status not in ^@terminal_statuses and
        s.teardown_requested_at < ^cutoff
    )
    |> Repo.all()
    |> Repo.preload(:conversations)
    |> Enum.reject(&Lifecycle.any_server_alive?/1)
    |> Enum.map(&finish_teardown/1)
    |> length()
  end

  defp finish_teardown(%Sandbox{} = sandbox) do
    was = sandbox.status

    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{
        status: "terminated",
        terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Logger.warning(
      "reaper: finished abandoned teardown of sandbox #{sandbox.id} " <>
        "(#{sandbox.machine_name}) — fenced at #{sandbox.teardown_requested_at}, " <>
        "still #{was} #{@fenced_teardown_grace_minutes}m later"
    )

    # The conversations are left alone for the same reason `expire/2` leaves
    # them: reclaiming a machine is not deleting the thread that ran on it.
    record_reap(sandbox, "sandbox.teardown_reconciled", %{
      "previous_status" => was,
      "teardown_requested_at" => DateTime.to_iso8601(sandbox.teardown_requested_at),
      "grace_minutes" => @fenced_teardown_grace_minutes
    })

    sandbox
  end

  # ── pass 2: terminal rows whose sprite is still there ─────────────────────

  defp destroy_dead_sprites(live_by_provider) do
    Sandbox
    |> where([s], s.status in ^@terminal_statuses)
    |> select([s], {s.id, s.machine_name, s.provider})
    |> Repo.all()
    |> Enum.filter(fn {_id, name, provider} ->
      case Map.fetch(live_by_provider, provider_atom(provider)) do
        # Rows on a provider whose listing failed (or that is disabled) are
        # skipped, not destroyed — the next run with credentials converges.
        {:ok, live_names} -> MapSet.member?(live_names, name)
        :error -> false
      end
    end)
    |> Enum.take(@destroy_limit)
    |> Enum.count(fn {id, name, provider} -> destroy(id, name, provider_atom(provider)) end)
  end

  defp provider_atom(provider), do: Conversations.sandbox_provider_atom(%{provider: provider})

  defp destroy(sandbox_id, machine_name, provider) do
    # build_handle/2 is pure — we already know the sandbox exists (it came
    # out of the listing), so there is nothing to look up first.
    case Managoat.Sandbox.destroy(Managoat.Sandbox.build_handle(provider, machine_name)) do
      :ok ->
        Logger.info("reaper: destroyed leaked sprite #{machine_name} (sandbox #{sandbox_id})")
        true

      {:error, reason} ->
        # Left for the next run rather than retried here; the row stays terminal
        # either way, so nothing is lost by being slow about it.
        Logger.warning("reaper: destroy failed for #{machine_name}: #{inspect(reason)}")
        false
    end
  end

  # ── pass 3: sprites with no row — counted, never touched ──────────────────

  @doc false
  def report_untracked(live_by_provider) do
    Enum.reduce(live_by_provider, 0, fn {provider, live_names}, total ->
      known =
        Sandbox
        |> where([s], s.provider == ^Atom.to_string(provider))
        |> select([s], s.machine_name)
        |> Repo.all()
        |> MapSet.new()

      untracked = MapSet.difference(live_names, known)
      count = MapSet.size(untracked)

      if count > 0 do
        sample = untracked |> Enum.sort() |> Enum.take(10) |> Enum.join(", ")

        Logger.info(
          "reaper: #{count} #{provider} sandbox(es) have no sandbox row and were " <>
            "left alone (sample: #{sample})"
        )
      end

      :telemetry.execute([:fountain, :reaper, :untracked], %{count: count}, %{
        provider: provider
      })

      total + count
    end)
  end

  # ── sprites.dev ───────────────────────────────────────────────────────────

  # One listing per provider, isolated: one backend being down must not stop
  # another's reconciliation. Sprites is always attempted (the historical
  # default may hold rows even when its credential was pulled); other
  # providers only when enabled. Pagination is the adapter's problem — a
  # first-page-only listing looks complete, which for a function that decides
  # what to delete is the worst possible shape of wrong, so adapters return
  # {:error, :truncated} rather than a partial view.
  defp list_by_provider do
    [:sprites | Fountain.SandboxProviders.enabled_providers()]
    |> Enum.uniq()
    |> Map.new(fn provider -> {provider, safe_list(provider)} end)
  end

  defp safe_list(provider) do
    Managoat.Sandbox.list_all_names(provider)
  rescue
    e -> {:error, e}
  end
end
