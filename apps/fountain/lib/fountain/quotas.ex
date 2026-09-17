defmodule Fountain.Quotas do
  @moduledoc """
  Per-tenant resource caps.

  Fountain provisions every tenant's sandboxes with a single platform-level
  `SPRITES_TOKEN` and pays the resulting bill (ADR 0005), so a per-tenant
  concurrency cap is the primary defence against one account — whether abusive,
  scripted, or merely enthusiastic — consuming the platform's capacity.

  The cap is funded by the balance (ADR 0031): a tenant may run
  `clamp(balance ÷ reserve, floor, ceiling)` sandboxes at once, so nobody can
  start a fleet they cannot pay for, and a bigger balance unlocks more. A
  comped account, and a deployment with billing off, get the ceiling.
  `users.sandbox_limit_override` wins when it is set, which is the admin
  lever the rule cannot express: raise it for a trusted tenant, drop it to
  zero during abuse. A null override means "whatever the balance funds".

  A fleet ceiling bounds the sum across every tenant to what the providers
  allow; `with_sandbox_reservation/3` checks it under a global lock and
  refuses with `:fleet_full`, which is capacity, not a billing state.

  ## What counts

  A sandbox counts while it is compute: `pending`, `starting` and `ready`.
  `pending` and `starting` count because a sprite is being paid for from the
  moment provisioning begins, and counting only `ready` would let a burst of
  concurrent starts sail past the cap before any of them settle. `suspended`
  deliberately does NOT count — a parked sprite is scaled to zero and costs
  ~nothing (decisions/0017) — which means this set is narrower than the admin
  sandbox view's "anything non-terminal": the admin table will list a suspended
  sandbox that the per-user counter ignores. Waking one re-runs the quota gate
  (`Fountain.Machines.Resume`). Unconfirmed resets also count,
  even on parked machines, and cannot use the replacement exclusion.

  **A machine being woken counts from the moment it is admitted** (ADR 0058
  stage 7a): a row stamped `transition: "resuming"` under a *live* lease is
  compute that has been paid for and is on its way up, and it counts even while
  its status still says `suspended`. That stamp is written inside
  `with_sandbox_reservation/3`'s own transaction, which is what makes the
  reservation a reservation rather than a read — without it, two wakes of two
  parked machines would each pass a check the other was invisible to and both
  come up past a cap with room for one.

  The live-lease half is what keeps it honest in the other direction. A resume
  whose owner died leaves the stamp behind, and counting *that* would hold a
  tenant's slot until some later sweep cleared it. A lease that has expired is
  an abandoned operation for the next owner to take over — stage 6a's rule,
  applied here — so the slot comes back when the lease does. The clock is the
  database's (stage 7a), the same one `lease_until` is written from.

  **A machine being destroyed counts until its row is terminal** (stage 9a),
  and this one takes no lease reading at all. `transition: "destroying"` is
  durable intent rather than an operation in flight: an owner that died between
  the fence and the finalize left a machine that is still at the provider and
  still billing, and the driver that ends it runs on a cron. So the slot is held
  for as long as the row is, which is what `reset_requested_at` above has always
  done for the reset — the same statement on the column stage 9b keeps.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  @active_statuses ~w(pending starting ready)

  @doc """
  Number of sandboxes currently counting against `user_id`'s cap.

  Pass `exclude: sandbox_id` to leave a specific sandbox out. The wake path
  needs this: it provisions the replacement before retiring the sandbox it is
  replacing, so without the exclusion a conversation sitting exactly at the cap
  could never be woken even though concurrency would not increase.
  """
  @spec active_sandbox_count(binary(), keyword()) :: non_neg_integer()
  def active_sandbox_count(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from s in active_sandboxes(),
        where: s.user_id == ^user_id,
        select: count(s.id)

    query =
      case Keyword.get(opts, :exclude) do
        nil ->
          query

        excluded ->
          from s in query,
            where:
              s.id != ^excluded or not is_nil(s.reset_requested_at) or
                s.transition == "destroying"
      end

    Repo.one(query) || 0
  end

  @doc """
  Active-sandbox counts for every user with at least one, in a single query —
  for the admin view, which refreshes on a timer and must not run a count per
  row (the same contract as `Fountain.Billing.usage_summaries/2`).

  Returns `%{user_id => count}`; users with no active sandboxes are absent.
  """
  @spec active_sandbox_counts() :: %{optional(binary()) => non_neg_integer()}
  def active_sandbox_counts do
    from(s in active_sandboxes(),
      group_by: s.user_id,
      select: {s.user_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The concurrency cap for `user_id`: the override if it has one, otherwise
  what the balance funds (ADR 0031).

  A user who cannot be found at all gets the floor, so a lookup failure
  tightens rather than removes the limit.
  """
  @spec sandbox_limit(binary()) :: non_neg_integer()
  def sandbox_limit(user_id) when is_binary(user_id) do
    query =
      from u in User,
        where: u.id == ^user_id,
        select: {u.sandbox_limit_override, u.credit_balance_cents, u.comped}

    case Repo.one(query) do
      {override, balance, comped} -> resolve_limit(override, balance, comped)
      nil -> 0
    end
  end

  @doc """
  The same answer as `sandbox_limit/1` for a user already loaded — for the
  admin table, which shows the cap on every row and must not run a query per
  row (the same contract as `active_sandbox_counts/0`).
  """
  @spec sandbox_limit_for(User.t()) :: non_neg_integer()
  def sandbox_limit_for(%User{} = user),
    do: resolve_limit(user.sandbox_limit_override, user.credit_balance_cents, user.comped)

  defp resolve_limit(override, _balance, _comped) when is_integer(override), do: override

  defp resolve_limit(_override, balance, comped) do
    %{reserve_cents: reserve, cap_floor: floor, cap_ceiling: ceiling} = settings()

    cond do
      not Fountain.Credits.enabled?() -> ceiling
      comped == true -> ceiling
      # Nothing in the balance funds nothing. The credit gate runs before the
      # quota check under the reservation lock, so this account is refused as
      # `insufficient_credits`, never as a 0/0 quota.
      (balance || 0) <= 0 -> 0
      true -> balance |> funded(reserve) |> max(floor) |> min(ceiling)
    end
  end

  defp funded(_balance, 0), do: 0
  defp funded(balance, reserve), do: div(balance, reserve)

  @doc "Live sandboxes across every tenant, against the fleet ceiling."
  @spec fleet_count() :: non_neg_integer()
  def fleet_count do
    Repo.one(from(s in active_sandboxes(), select: count(s.id))) || 0
  end

  # A reset holds its slot until deletion is confirmed, including a reset
  # requested while parked. Replacement exclusions cannot spend that slot.
  #
  # The fourth arm is ADR 0058 stage 9a's, and it is the second arm written
  # again on the column that will outlive it: a `destroying` stamp is the same
  # durable statement `reset_requested_at` makes, so a machine wearing one goes
  # on holding its slot until the row is terminal. **No lease condition**, which
  # is the difference from the `resuming` arm below and the whole of the stage:
  # a resume whose owner died is an abandoned operation and gives the slot back
  # when its lease lapses, where a destroy whose owner died is an *unfinished*
  # one — the machine is still at the provider and still billing, and
  # `SandboxReaper.sweep_fenced_teardowns/0`'s driver is what ends it. Counting
  # it as free would let a tenant start a machine against a slot two machines
  # are using.
  #
  # The third arm is ADR 0058 stage 7a's resume reservation, and it is the one
  # rendering of `Machines.Lease.live?/2` that had to be written in SQL: this is
  # a `count(*)` under an advisory lock, and pulling every candidate row into
  # Elixir to fold a predicate over it would turn a counter into a scan. The two
  # halves are the same two `live?/2` decides on — a holder, and a deadline that
  # has not passed — and `quotas_test.exs` pins them against it so the copy
  # cannot drift the way stage 6a's three copies had. `statement_timestamp()`
  # for the reason `Lease`'s moduledoc gives — `now()` freezes for the whole of
  # the reservation's transaction, and this count runs inside one — and
  # `AT TIME ZONE 'UTC'` for the other reason it gives: `lease_until` is
  # `timestamp without time zone`, so comparing it against a bare `timestamptz`
  # casts through the session's `TimeZone`, and a machine on its way up would
  # stop counting on any connection not running in UTC.
  defp active_sandboxes do
    from s in Sandbox,
      where:
        s.status in @active_statuses or
          (not is_nil(s.reset_requested_at) and s.status not in ["terminated", "failed"]) or
          (s.transition == "destroying" and s.status not in ["terminated", "failed"]) or
          (s.transition == "resuming" and not is_nil(s.lease_node) and
             s.lease_until > fragment("statement_timestamp() AT TIME ZONE 'UTC'"))
  end

  @doc "The reserve, floor, ceiling and fleet ceiling in force."
  @spec settings() :: %{
          reserve_cents: non_neg_integer(),
          cap_floor: non_neg_integer(),
          cap_ceiling: non_neg_integer(),
          fleet_ceiling: non_neg_integer()
        }
  def settings do
    cfg = Application.get_env(:fountain, :sandboxes, [])

    %{
      reserve_cents: Keyword.get(cfg, :reserve_cents, 200),
      cap_floor: Keyword.get(cfg, :cap_floor, 2),
      cap_ceiling: Keyword.get(cfg, :cap_ceiling, 20),
      fleet_ceiling: Keyword.get(cfg, :fleet_ceiling, 20)
    }
  end

  @doc """
  Check the deployment against the fleet ceiling. `:ok`, or
  `{:error, :fleet_full}` — every provider slot is in use, whoever holds them.
  """
  @spec check_fleet_ceiling(keyword()) :: :ok | {:error, :fleet_full}
  def check_fleet_ceiling(opts \\ []) do
    ceiling = settings().fleet_ceiling

    count =
      case Keyword.get(opts, :exclude) do
        nil ->
          fleet_count()

        excluded ->
          Repo.one(
            from(s in active_sandboxes(),
              where:
                s.id != ^excluded or not is_nil(s.reset_requested_at) or
                  s.transition == "destroying",
              select: count(s.id)
            )
          ) || 0
      end

    if count < ceiling, do: :ok, else: {:error, :fleet_full}
  end

  @doc """
  Check `user_id` against the sandbox concurrency cap.

  Returns `:ok`, or `{:error, {:sandbox_quota_exceeded, %{count: n, limit: n}}}`.

  Call this immediately before creating a sandbox row — every row precedes a
  `Managoat.Sandbox.create/3`, so guarding row creation guards sandbox
  creation at the provider.
  """
  @spec check_sandbox_quota(binary(), keyword()) ::
          :ok
          | {:error,
             {:sandbox_quota_exceeded, %{count: non_neg_integer(), limit: non_neg_integer()}}}
  def check_sandbox_quota(user_id, opts \\ []) when is_binary(user_id) do
    limit = sandbox_limit(user_id)
    count = active_sandbox_count(user_id, opts)

    if count < limit do
      :ok
    else
      {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}}
    end
  end

  # Advisory-lock namespace for sandbox reservations; the second key is a hash
  # of the user id. A hash collision between users only over-serializes two
  # tenants' creations — never under-counts.
  @lock_namespace 4315
  # One key for the whole fleet, so the ceiling is counted by one reservation
  # at a time. Taken before the per-user lock, always, so two reservations
  # cannot deadlock on each other.
  @fleet_lock_key 0

  @doc """
  Check the cap and run `fun` (which must create the sandbox row) atomically,
  under a per-user Postgres advisory lock.

  `check_sandbox_quota/2` alone is check-then-insert: N concurrent requests at
  the cap could each read `count < limit` before any row landed, and each go
  on to provision a paid sprite (#330). The lock serializes check + insert per
  user, so the second request re-counts after the first has committed. Scoped
  per user: one tenant's burst cannot queue behind another's.

  `fun` must return `{:ok, value}` or `{:error, reason}`; any error — the
  quota's or `fun`'s — rolls the whole reservation back.
  """
  @spec with_sandbox_reservation(binary(), keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_sandbox_reservation(user_id, quota_opts \\ [], fun) when is_binary(user_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@lock_namespace, @fleet_lock_key])

      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @lock_namespace,
        :erlang.phash2(user_id)
      ])

      # The fleet ceiling, the tenant's cap and the balance precheck all live
      # under the locks (ADR 0030 decision 6, ADR 0031): two requests at the
      # last slot or the last cent must not both read "room" and both
      # provision. The turn that then burns the balance may still go
      # negative; that is the soft stop, not a hole.
      # Balance before cap: an unfunded account's cap is 0, and "out of
      # credit" is the answer it should hear, not "0/0 sandboxes".
      with :ok <- check_fleet_ceiling(quota_opts),
           :ok <- Fountain.Credits.gate(user_id),
           :ok <- check_sandbox_quota(user_id, quota_opts),
           {:ok, value} <- fun.() do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Sandbox statuses that count against the cap."
  def active_statuses, do: @active_statuses
end
