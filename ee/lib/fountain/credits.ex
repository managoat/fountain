defmodule Fountain.Credits do
  @moduledoc """
  The prepaid credit ledger (ADR 0030).

  A tenant's balance is a number of **cents**, cached on
  `users.credit_balance_cents` and backed by the append-only `credit_ledger`.
  Money comes in as a grant (the opening grant at verification, an operator's
  grant) or a purchase, and goes out as a burn (turn hours, inference),
  an expiry, or a clawback after a refund or dispute.

  Three properties every writer relies on:

    * **Idempotent.** Every row carries a unique `idempotency_key`. Posting the
      same key twice returns the original row and writes nothing, so a worker
      can re-price a turn, a webhook can arrive twice, and a sweep can restart
      without touching the balance.
    * **The cache is the balance.** The row and the `UPDATE users SET
      credit_balance_cents = credit_balance_cents + amount` land in one
      transaction; a gate reads the column and never sums the ledger.
      `recompute_balance/1` exists for reconciliation, not for reads.
    * **Every credit row is a lot.** `remaining_cents` on a grant or a
      purchase is what is still unspent of it. A debit consumes lots in a
      fixed order — the lot it names (`:lot_id`: an expiry takes from its own
      grant, a clawback from its own purchase), then the earliest expiry,
      then purchased money — under a row lock on the user, so two debits
      cannot both consume the same cent. A credit posted against a negative
      balance repays the debt first and only the rest becomes a lot. What a
      surface calls "expiring" or "purchased" is read off the lots, never
      inferred from the balance.
    * **Short-circuit before the ledger.** `check_balance/1` answers `:ok` for
      a deployment with billing off and for a comped tenant *before* reading
      the balance, so a self-hosted install and a comp never brick at zero
      (ADR 0030 decision 7).

  ## Who writes and who reads

  `Workers.CreditPricer` burns closed turns and platform inference;
  `Workers.CreditExpirer` (and the pricer's tick) expires grants; `Credits.Purchases` grants packs and claws them back;
  `grant_opening/2` is posted by `Accounts.verify_email/2`; an operator grants
  from the admin panel. `gate/1`, behind `Billing.check_spend/1`, is what
  every door reads (ADR 0031).

  ## Audit

  Every posted row leaves one `credit.*` event: `credit.granted`,
  `credit.purchased`, `credit.burned`, `credit.expired`, `credit.clawed_back`.
  Metadata carries the amount, reason and resource reference — cents are not
  tenant data — never a balance, which is derivable and would go stale.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  require Logger

  @type post_result ::
          {:ok, LedgerEntry.t()} | {:ok, :duplicate, LedgerEntry.t()} | {:error, term()}

  @doc """
  Whether credits are on for this deployment (`CREDITS_ENABLED`, ADR 0031).
  Off, nothing is priced, granted, gated or shown: a self-hosted install
  runs with no money in it at all.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fountain, :credits_enabled, true)

  # ---------------------------------------------------------------------------
  # Prices
  # ---------------------------------------------------------------------------

  @doc """
  The customer price card, in cents. `:turn_hour` is what one hour of
  `turn_seconds` burns (ADR 0030 decision 3; the number is a placeholder until
  #1038 produces a provider cost).

  Read from `config :fountain, :credits`; runtime.exs fills it from
  `CREDIT_TURN_HOUR_CENTS`.
  """
  @spec price_card() :: %{turn_hour: non_neg_integer()}
  def price_card do
    cfg = Application.get_env(:fountain, :credits, [])
    %{turn_hour: Keyword.get(cfg, :turn_hour_cents, 25)}
  end

  @doc """
  The credit packs a tenant can buy, in cents, ascending. Default
  $10 / $25 / $100 (`CREDIT_PACKS_CENTS="1000,2500,10000"`).
  """
  @spec packs() :: [pos_integer()]
  def packs do
    Application.get_env(:fountain, :credits, [])
    |> Keyword.get(:packs_cents, [1_000, 2_500, 10_000])
  end

  @doc """
  Cents that `turn_seconds` of conversation time burns, rounded to the
  nearest cent. Integer arithmetic on purpose: a ledger of fractional cents
  is a ledger nobody can reconcile.
  """
  @spec turn_cost_cents(non_neg_integer()) :: non_neg_integer()
  def turn_cost_cents(turn_seconds) when is_integer(turn_seconds) and turn_seconds >= 0 do
    div(turn_seconds * price_card().turn_hour + 1_800, 3_600)
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  The tenant's balance in cents, from the cache. Negative is possible: an
  in-flight turn that crosses zero finishes and lands as debt (ADR 0030
  decision 6), and a clawback after a refund can take a spent balance below
  zero.
  """
  @spec balance(User.t() | binary()) :: integer()
  def balance(%User{credit_balance_cents: cents}) when is_integer(cents), do: cents

  def balance(user_id) when is_binary(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.credit_balance_cents)
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Whether the tenant may spend. `:ok` when billing is off or the account is
  comped, before any balance read; `:ok` when the spendable balance is
  positive; `{:error, :insufficient_credits}` otherwise.

  Spendable is the cached balance less what expired lots still hold: a grant
  past its date stops funding new work the moment it passes, not when the
  expiry sweep gets round to writing the row (`Workers.CreditExpirer`).
  `Billing.check_spend/1` is the door; every spend calls that.

  Options: `:now` pins the clock for the expiry read; `:min` is the least
  spendable balance that passes (default 1 cent — "positive").
  """
  @spec check_balance(User.t() | binary(), keyword()) :: :ok | {:error, :insufficient_credits}
  def check_balance(subject, opts \\ []) do
    min = Keyword.get(opts, :min, 1)
    subject = billing_subject(subject)

    cond do
      not enabled?() -> :ok
      comped?(subject) -> :ok
      spendable(subject, Keyword.get(opts, :now) || DateTime.utc_now()) >= min -> :ok
      true -> {:error, :insufficient_credits}
    end
  end

  # Whose money answers for this work (ADR 0044). A loaded `%User{}` that is not
  # a principal is handed back untouched — resolving it to its own id would turn
  # every gate into a database read and quietly stop honouring the balance the
  # caller loaded. A principal is resolved: unclaimed, to itself and the
  # application's introductory grant; claimed, to the account that claimed it,
  # so a machine started anonymously keeps running on its new owner's balance.
  defp billing_subject(%User{principal: false} = user), do: user
  defp billing_subject(%User{id: id}), do: Fountain.Principals.billing_subject_id(id)

  defp billing_subject(user_id) when is_binary(user_id),
    do: Fountain.Principals.billing_subject_id(user_id)

  defp spendable(subject, now), do: balance(subject) - expired_unspent(user_id_of(subject), now)

  defp user_id_of(%User{id: id}), do: id
  defp user_id_of(user_id) when is_binary(user_id), do: user_id

  # What lots past their date still hold: money the sweep will take back and
  # that must not fund new work in the meantime.
  defp expired_unspent(user_id, now) do
    from(e in LedgerEntry,
      where: e.user_id == ^user_id and e.remaining_cents > 0,
      where: not is_nil(e.expires_at) and e.expires_at <= ^now,
      select: coalesce(sum(e.remaining_cents), 0)
    )
    |> Repo.one()
  end

  defp comped?(%User{comped: comped}), do: comped == true

  defp comped?(user_id) when is_binary(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.comped) |> Repo.one() == true
  end

  @doc """
  The ledger for one tenant, newest first by `seq` (insertion order; a grant
  and its burn can share an `inserted_at` second). `:limit` defaults to 100.
  """
  @spec list_entries(binary(), keyword()) :: [LedgerEntry.t()]
  def list_entries(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 100)

    from(e in LedgerEntry,
      where: e.user_id == ^user_id,
      order_by: [desc: e.seq],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Cents the ledger took from one tenant in `[period_start, period_end)`:
  every `burn_*` row by `inserted_at`, as a positive number. Zero with
  billing off. This is what the customer was charged for the window; the
  usage numbers beside it are what will be charged when in-flight turns
  close, and the two are not expected to agree to the cent.
  """
  @spec burned_between(binary(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def burned_between(user_id, %DateTime{} = period_start, %DateTime{} = period_end)
      when is_binary(user_id) do
    if enabled?() do
      from(e in LedgerEntry,
        where: e.user_id == ^user_id and like(e.reason, "burn_%"),
        where: e.inserted_at >= ^period_start and e.inserted_at < ^period_end,
        select: coalesce(sum(e.amount_cents), 0)
      )
      |> Repo.one()
      |> Kernel.-()
    else
      0
    end
  end

  @doc """
  What the lot posted under `idempotency_key` still holds for `user_id`, in
  cents, or zero when there is no such lot.

  For a refund that must hand back only the unspent part of a specific grant
  (ADR 0044): the balance is the wrong number there, because it also carries
  money from somewhere else.
  """
  @spec lot_remaining_for(binary(), String.t()) :: non_neg_integer()
  def lot_remaining_for(user_id, idempotency_key)
      when is_binary(user_id) and is_binary(idempotency_key) do
    from(e in LedgerEntry,
      where: e.user_id == ^user_id and e.idempotency_key == ^idempotency_key,
      select: e.remaining_cents
    )
    |> Repo.one()
    |> Kernel.||(0)
    |> max(0)
  end

  @doc "One entry by idempotency key, or nil."
  @spec get_by_key(String.t()) :: LedgerEntry.t() | nil
  def get_by_key(key) when is_binary(key), do: Repo.get_by(LedgerEntry, idempotency_key: key)

  @doc """
  Sum the ledger for one tenant and write it to the cache. For reconciliation
  (a release task, a test); never on a request path. Returns the recomputed
  balance.
  """
  @spec recompute_balance(binary()) :: integer()
  def recompute_balance(user_id) when is_binary(user_id) do
    total =
      from(e in LedgerEntry,
        where: e.user_id == ^user_id,
        select: coalesce(sum(e.amount_cents), 0)
      )
      |> Repo.one()

    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [credit_balance_cents: total])

    total
  end

  @doc """
  Tenants whose cached balance disagrees with their ledger — `[{user_id,
  cached, actual}]`. Empty is the invariant.
  """
  @spec drift() :: [{binary(), integer(), integer()}]
  def drift do
    from(u in User,
      left_join: e in LedgerEntry,
      on: e.user_id == u.id,
      group_by: u.id,
      having: u.credit_balance_cents != coalesce(sum(e.amount_cents), 0),
      select: {u.id, u.credit_balance_cents, coalesce(sum(e.amount_cents), 0)}
    )
    |> Repo.all()
  end

  @doc """
  The spend gate (ADR 0030 decision 6, ADR 0031): `check_balance/2` with the
  defaults. `Billing.check_spend/1` is this; call that, not this, from a door.
  """
  @spec gate(User.t() | binary()) :: :ok | {:error, :insufficient_credits}
  def gate(subject) do
    case check_balance(subject) do
      :ok ->
        :ok

      {:error, :insufficient_credits} = refusal ->
        # An unclaimed principal running out of its introductory grant is a
        # thing the application that opened it needs told (ADR 0044). Stamped
        # once on the grant, not once per refused request: this runs at every
        # door that spends.
        Fountain.Principals.note_budget_exhausted(subject_id(subject))
        refusal
    end
  end

  defp subject_id(%User{id: id}), do: id
  defp subject_id(user_id) when is_binary(user_id), do: user_id

  @doc """
  The one shape every surface renders (the billing page, the dashboard,
  `GET /api/account/billing`, the admin account view), so they cannot
  disagree.

    * `:active?` — `Credits.enabled?/0`; when false the other numbers are
      zero and should not be shown
    * `:balance_cents` — the cached balance, possibly negative
    * `:expiring_cents` / `:expires_at` — what the earliest live grant still
      has unspent, and when it goes
    * `:purchased_cents` — how much of the balance is paid-for money, which
      never expires
    * `:price_card` — `price_card/0`; `turn_hour` on it is the price of one
      turn hour
  """
  @spec summary(User.t(), keyword()) :: %{
          active?: boolean(),
          balance_cents: integer(),
          expiring_cents: non_neg_integer(),
          expires_at: DateTime.t() | nil,
          purchased_cents: non_neg_integer(),
          price_card: map()
        }
  def summary(%User{} = user, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    card = price_card()

    if enabled?() do
      balance = balance(user)
      purchased = purchased_remaining(user.id)

      {expiring, expires_at} =
        case live_grants(user.id, now) do
          [] -> {0, nil}
          [first | _] -> {unspent_of(first), first.expires_at}
        end

      %{
        active?: true,
        balance_cents: balance,
        expiring_cents: expiring,
        expires_at: expires_at,
        purchased_cents: purchased,
        price_card: card
      }
    else
      %{
        active?: false,
        balance_cents: 0,
        expiring_cents: 0,
        expires_at: nil,
        purchased_cents: 0,
        price_card: card
      }
    end
  end

  @doc "Open lots that expire, earliest first: grants with something left."
  @spec live_grants(binary(), DateTime.t()) :: [LedgerEntry.t()]
  def live_grants(user_id, %DateTime{} = now) when is_binary(user_id) do
    from(e in LedgerEntry,
      where: e.user_id == ^user_id and e.remaining_cents > 0,
      where: not is_nil(e.expires_at) and e.expires_at > ^now,
      order_by: [asc: e.expires_at, asc: e.seq]
    )
    |> Repo.all()
  end

  @doc "How much of `grant` is still unspent: its lot, read fresh."
  @spec unspent_of(LedgerEntry.t()) :: non_neg_integer()
  def unspent_of(%LedgerEntry{id: id}) do
    from(e in LedgerEntry, where: e.id == ^id, select: e.remaining_cents)
    |> Repo.one()
    |> Kernel.||(0)
  end

  # Non-expiring lots with something left: bought money, and admin grants.
  defp purchased_remaining(user_id) do
    from(e in LedgerEntry,
      where: e.user_id == ^user_id and e.remaining_cents > 0 and is_nil(e.expires_at),
      select: coalesce(sum(e.remaining_cents), 0)
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # Writes
  # ---------------------------------------------------------------------------

  @doc """
  The opening grant a new account gets (ADR 0031 decision 3):
  `credits.opening_cents` expiring `credits.opening_days` after now, once per
  account. Nothing when billing is off.
  """
  @spec grant_opening(User.t() | binary(), keyword()) :: post_result() | {:ok, :not_billed}
  def grant_opening(subject, opts \\ [])
  def grant_opening(%User{id: id}, opts), do: grant_opening(id, opts)

  def grant_opening(user_id, opts) when is_binary(user_id) do
    cfg = Application.get_env(:fountain, :credits, [])
    cents = Keyword.get(cfg, :opening_cents, 500)
    days = Keyword.get(cfg, :opening_days, 14)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    if enabled?() and cents > 0 do
      grant(user_id, cents, "grant_opening",
        idempotency_key: "grant_opening:#{user_id}",
        expires_at: now |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second),
        resource_type: "opening",
        resource_id: user_id,
        actor: Keyword.get(opts, :actor, "system:registration")
      )
    else
      {:ok, :not_billed}
    end
  end

  @doc """
  Put money in. `reason` is one of `LedgerEntry.credit_reasons/0`; `cents` is
  positive.

  Options: `:idempotency_key` (required), `:expires_at` (a grant that stops
  being spendable), `:resource_type` / `:resource_id`, `:metadata`, and the
  usual audit attribution (`:actor`, `:request_ip`).
  """
  @spec grant(binary(), pos_integer(), String.t(), keyword()) :: post_result()
  def grant(user_id, cents, reason, opts) when is_integer(cents) and cents > 0 do
    post(user_id, cents, reason, opts)
  end

  @doc """
  Take money out. `reason` is one of `LedgerEntry.debit_reasons/0`; `cents` is
  positive and is stored negated. A debit may drive the balance below zero;
  refusing to spend is the gate's job, not the ledger's.

  With `:lot_id` the debit consumes only that lot (an expiry takes from its
  own grant, a clawback from its own purchase) and whatever the lot cannot
  cover is debt on the balance — it never falls through to another lot,
  which is how an expiry could once take paid money.
  """
  @spec debit(binary(), pos_integer(), String.t(), keyword()) :: post_result()
  def debit(user_id, cents, reason, opts) when is_integer(cents) and cents > 0 do
    post(user_id, -cents, reason, opts)
  end

  @doc """
  Expire `grant`: debit what its lot still holds, under `expire:<grant_id>`,
  from that lot only. The amount is read inside the transaction, under the
  same row lock every post takes, so a burn racing the sweep cannot leave
  the expiry taking more than the grant had left. `{:ok, :nothing}` when the
  lot was already spent to zero (no row is written; a zero row is invalid).
  """
  @spec expire_lot(LedgerEntry.t(), keyword()) :: post_result() | {:ok, :nothing}
  def expire_lot(%LedgerEntry{amount_cents: granted} = grant, opts \\ []) when granted > 0 do
    opts =
      opts
      |> Keyword.put(:idempotency_key, "expire:#{grant.id}")
      |> Keyword.put(:lot_id, grant.id)
      |> Keyword.put(:cap_to_lot, true)
      |> Keyword.put_new(:resource_type, "credit_ledger")
      |> Keyword.put_new(:resource_id, grant.id)
      |> Keyword.put_new(:metadata, %{
        "grant_reason" => grant.reason,
        "granted_cents" => grant.amount_cents
      })

    case post(grant.user_id, -granted, "expire", opts) do
      {:error, :nothing_to_take} ->
        # A lot at zero is either spent or already expired; say which.
        case get_by_key(opts[:idempotency_key]) do
          nil -> {:ok, :nothing}
          existing -> {:ok, :duplicate, existing}
        end

      other ->
        other
    end
  end

  @doc """
  Post one signed row and move the cached balance by the same amount, in one
  transaction. Returns `{:ok, entry}`, `{:ok, :duplicate, entry}` when the
  idempotency key was already posted (nothing written), or an error.

  Prefer `grant/4` and `debit/4`, which fix the sign.
  """
  @spec post(binary(), integer(), String.t(), keyword()) :: post_result()
  def post(user_id, amount_cents, reason, opts)
      when is_binary(user_id) and is_integer(amount_cents) do
    key = Keyword.fetch!(opts, :idempotency_key)

    attrs = %{
      user_id: user_id,
      amount_cents: amount_cents,
      reason: reason,
      idempotency_key: key,
      resource_type: Keyword.get(opts, :resource_type),
      resource_id: Keyword.get(opts, :resource_id),
      expires_at: Keyword.get(opts, :expires_at),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    changeset = LedgerEntry.changeset(%LedgerEntry{}, attrs)

    if changeset.valid? do
      changeset
      |> insert_and_move(Keyword.get(opts, :lot_id), Keyword.get(opts, :cap_to_lot, false))
      |> emit_posted()
      |> audited(opts)
    else
      {:error, changeset}
    end
  end

  # Every movement of money, measured where it actually happens (#1169).
  #
  # Emitting here rather than from each worker's return value is deliberate:
  # this is the ledger write, so the measurement cannot drift from the ledger
  # the way a separately-counted total can, and one event covers turns,
  # inference, expiry, grants and purchases at once. It is
  # outside the transaction — `insert_and_move/3` has already returned — for
  # the reason ADR 0013 gives about audit rows: work inside a transaction that
  # can fail takes the transaction with it.
  #
  # `reason` is the label because it is a closed vocabulary
  # (`LedgerEntry.debit_reasons/0` plus the credit reasons), so it cannot blow
  # up Prometheus cardinality. A duplicate posts nothing and measures nothing,
  # which is what makes "the pricer priced zero cents today" a real signal
  # rather than an artefact of the seven-day look-back re-reading old rows.
  defp emit_posted({:ok, %LedgerEntry{} = entry} = result) do
    :telemetry.execute(
      [:fountain, :credits, :posted],
      %{cents: abs(entry.amount_cents)},
      %{reason: entry.reason, direction: if(entry.amount_cents < 0, do: "debit", else: "credit")}
    )

    result
  end

  defp emit_posted(result), do: result

  # The unique index is the idempotency guard, and the duplicate is detected
  # *after* attempting the insert rather than by a lookup first: two workers
  # posting the same key at once must not both see "absent" and both move the
  # balance. A duplicate aborts the transaction, so the balance is untouched.
  defp insert_and_move(changeset, lot_id, cap_to_lot) do
    key = Ecto.Changeset.get_field(changeset, :idempotency_key)
    user_id = Ecto.Changeset.get_field(changeset, :user_id)
    requested = Ecto.Changeset.get_field(changeset, :amount_cents)

    Repo.transaction(fn ->
      # The user row is the lock for this tenant's lots: every post takes it,
      # so consumption and the balance move together and in order.
      case Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:user_not_found)

        %User{credit_balance_cents: before} ->
          # An expiry takes what its lot still holds, read under the lock.
          amount =
            if cap_to_lot and requested < 0,
              do: -min(-requested, lot_remaining(lot_id)),
              else: requested

          if amount == 0, do: Repo.rollback(:nothing_to_take)

          changeset =
            cond do
              amount > 0 ->
                Ecto.Changeset.put_change(changeset, :remaining_cents, lot_size(amount, before))

              amount != requested ->
                Ecto.Changeset.put_change(changeset, :amount_cents, amount)

              true ->
                changeset
            end

          case Repo.insert(changeset) do
            {:ok, entry} ->
              if amount < 0, do: consume_lots(user_id, -amount, lot_id)

              {1, _} =
                Repo.update_all(from(u in User, where: u.id == ^user_id),
                  inc: [credit_balance_cents: amount]
                )

              entry

            {:error, %Ecto.Changeset{} = cs} ->
              Repo.rollback(cs)
          end
      end
    end)
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :idempotency_key) do
          case get_by_key(key) do
            nil -> {:error, cs}
            existing -> {:ok, :duplicate, existing}
          end
        else
          {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A credit posted into debt repays it first; only the rest is spendable.
  defp lot_size(amount, balance_before), do: amount - min(amount, max(-balance_before, 0))

  defp lot_remaining(nil), do: 0

  defp lot_remaining(lot_id) do
    from(e in LedgerEntry, where: e.id == ^lot_id, select: e.remaining_cents)
    |> Repo.one()
    |> Kernel.||(0)
  end

  # Take `cents` from the open lots. A named lot is the only lot consumed
  # (an expiry or a clawback must never reach into another grant or into
  # paid money); otherwise the earliest expiry first, then non-expiring
  # money. Whatever no lot covers is debt, which the balance carries and the
  # next credit repays.
  defp consume_lots(user_id, cents, lot_id) do
    open =
      if lot_id do
        from(e in LedgerEntry,
          where: e.id == ^lot_id and e.user_id == ^user_id and e.remaining_cents > 0,
          select: {e.id, e.remaining_cents}
        )
      else
        from(e in LedgerEntry,
          where: e.user_id == ^user_id and e.remaining_cents > 0,
          order_by: [
            asc: fragment("case when ? is null then 1 else 0 end", e.expires_at),
            asc: e.expires_at,
            asc: e.seq
          ],
          select: {e.id, e.remaining_cents}
        )
      end
      |> Repo.all()

    # What is left after the lots is debt, carried by the balance.
    _debt =
      Enum.reduce_while(open, cents, fn {id, remaining}, left ->
        take = min(remaining, left)

        Repo.update_all(from(e in LedgerEntry, where: e.id == ^id),
          set: [remaining_cents: remaining - take]
        )

        if left - take == 0, do: {:halt, 0}, else: {:cont, left - take}
      end)

    :ok
  end

  @doc """
  Replay one tenant's ledger in order and rewrite every lot's
  `remaining_cents` from scratch. For the rows written before lots existed
  and for reconciliation; the live path keeps lots current by itself.
  Returns the number of lots.
  """
  @spec rebuild_lots(binary()) :: non_neg_integer()
  def rebuild_lots(user_id) when is_binary(user_id) do
    Repo.transaction(fn ->
      Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))

      entries =
        from(e in LedgerEntry,
          where: e.user_id == ^user_id,
          order_by: [asc: e.seq]
        )
        |> Repo.all()

      Repo.update_all(from(e in LedgerEntry, where: e.user_id == ^user_id),
        set: [remaining_cents: nil]
      )

      {_balance, lots} =
        Enum.reduce(entries, {0, 0}, fn entry, {balance, lots} ->
          if entry.amount_cents > 0 do
            Repo.update_all(from(e in LedgerEntry, where: e.id == ^entry.id),
              set: [remaining_cents: lot_size(entry.amount_cents, balance)]
            )

            {balance + entry.amount_cents, lots + 1}
          else
            consume_lots(user_id, -entry.amount_cents, replay_lot_id(entry))
            {balance + entry.amount_cents, lots}
          end
        end)

      lots
    end)
    |> case do
      {:ok, n} -> n
      {:error, reason} -> raise "rebuild_lots(#{user_id}) rolled back: #{inspect(reason)}"
    end
  end

  # The lot a historical debit was aimed at: an expiry names its grant as
  # the resource, a clawback keeps the purchase id in its metadata.
  defp replay_lot_id(%LedgerEntry{reason: "expire", resource_id: id}), do: id

  defp replay_lot_id(%LedgerEntry{reason: "clawback_" <> _, metadata: %{"purchase_id" => id}}),
    do: id

  defp replay_lot_id(_), do: nil

  # Recorded outside the transaction (ADR 0013): a best-effort audit write
  # inside it would take the ledger row down with it.
  defp audited({:ok, %LedgerEntry{} = entry} = ok, opts) do
    Audit.record(%{
      user_id: entry.user_id,
      action: audit_action(entry.reason),
      resource_type: "credit_ledger",
      resource_id: entry.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata:
        %{
          "amount_cents" => entry.amount_cents,
          "reason" => entry.reason,
          "target_type" => entry.resource_type,
          "target_id" => entry.resource_id
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)
    })

    ok
  end

  defp audited(other, _opts), do: other

  defp audit_action("purchase"), do: "credit.purchased"
  defp audit_action("grant_" <> _), do: "credit.granted"
  defp audit_action("burn_" <> _), do: "credit.burned"
  defp audit_action("expire"), do: "credit.expired"
  defp audit_action("clawback_" <> _), do: "credit.clawed_back"
  # The changeset's inclusion check makes this unreachable; the row has
  # committed by the time it runs, so a miss must not raise on the way out.
  defp audit_action(_other), do: "credit.posted"

  @doc ~S|Cents as a dollar string for display: `1240` → `"$12.40"`, `-5` → `"-$0.05"`.|
  @spec format_cents(integer()) :: String.t()
  def format_cents(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs = abs(cents)
    dollars = div(abs, 100)
    rem = rem(abs, 100)
    "#{sign}$#{dollars}.#{String.pad_leading(Integer.to_string(rem), 2, "0")}"
  end
end
