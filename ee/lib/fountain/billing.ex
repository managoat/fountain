defmodule Fountain.Billing do
  @moduledoc """
  The money side that is not the ledger: the Stripe customer and webhooks,
  usage summaries, provider spend and the admin overview. The name stays
  (#1144) — this is billing in the sense of "what Fountain is billed and
  reports", not the retired subscription; the switch, the gate and the
  customer-facing surfaces are `Fountain.Credits` and `Credits*`.

  Billing context (ADR 0031): the credit gate, the Stripe till, and usage
  aggregation.

  Credits are the product. What lives here is what is not the ledger itself
  (`Fountain.Credits`): `enabled?/0`, `check_spend/1` (the gate every spend
  passes), the Stripe customer and webhook plumbing that sells packs and
  claws them back, the comp lever, and the usage summaries the surfaces
  render.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.Repo

  @doc """
  The gate every spend passes (ADR 0031): the balance. `:ok` when billing is
  off, the account is comped, or the balance is positive; in-flight turns
  finish (ADR 0030 decision 6).
  """
  @spec check_spend(User.t() | binary()) :: :ok | {:error, :insufficient_credits}
  def check_spend(subject), do: Fountain.Credits.gate(subject)

  @doc """
  What this deployment's platform inference keys have cost today, in cents,
  across every tenant — the number `Fountain.PlatformInference` holds against
  `PLATFORM_INFERENCE_DAILY_CENTS` (#1388).

  `nil` with credits off: nothing is priced then (ADR 0031), so there is no
  spend to report and "zero" would be a claim rather than an answer.

  A UTC day, deliberately, and not each tenant's billing window: the ceiling
  is a property of the deployment's own bill, and a sum over windows that
  each start on a different day is not a number to bound anything with — the
  same reasoning `Finance.summary/1` gives for the calendar month.
  """
  @spec platform_inference_spend_today(DateTime.t() | nil) :: non_neg_integer() | nil
  def platform_inference_spend_today(now \\ nil) do
    if Fountain.Credits.enabled?() do
      now = now || DateTime.utc_now()
      day_start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      Repo.one(
        from e in Fountain.Credits.LedgerEntry,
          where: e.reason == "burn_inference" and e.inserted_at >= ^day_start,
          select: coalesce(sum(-e.amount_cents), 0)
      )
    end
  end

  @doc """
  Creates a Stripe Customer for the given user and stores its id.

  Customer only: a customer is what Checkout attaches a credit-pack payment
  to, and what a refund or dispute is traced back through. Nothing is
  subscribed and nothing is charged here (ADR 0031).
  """
  @spec create_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def create_stripe_customer(%User{} = user) do
    with {:ok, %Stripe.Customer{id: customer_id}} <-
           Stripe.Customer.create(%{email: user.email, metadata: %{"user_id" => user.id}}) do
      user
      |> User.billing_changeset(%{stripe_customer_id: customer_id})
      |> Repo.update()
    end
  end

  @doc """
  Make an account free: its balance is never checked and nothing is refused
  (ADR 0031). Reversible with `revoke_comp/1`. Burns are still written, so
  Finance can see what the comp cost.
  """
  @spec comp_account(User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def comp_account(user, opts \\ [])
  def comp_account(%User{comped: true} = user, _opts), do: {:ok, user}

  def comp_account(%User{} = user, opts) do
    user
    |> User.comp_changeset(%{comped: true})
    |> Repo.update()
    |> audit_comp(user, "billing.comp.granted", opts)
  end

  @doc "Undo `comp_account/2`: the balance is checked again from the next spend."
  @spec revoke_comp(User.t(), keyword()) :: {:ok, User.t()} | {:error, :not_comped}
  def revoke_comp(user, opts \\ [])
  def revoke_comp(%User{comped: false}, _opts), do: {:error, :not_comped}

  def revoke_comp(%User{} = user, opts) do
    user
    |> User.comp_changeset(%{comped: false})
    |> Repo.update()
    |> audit_comp(user, "billing.comp.revoked", opts)
  end

  defp audit_comp({:ok, %User{} = updated} = ok, %User{} = before, action, opts) do
    Audit.record(%{
      user_id: updated.id,
      action: action,
      resource_type: "user",
      resource_id: updated.id,
      actor: Keyword.get(opts, :actor, "admin"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"from" => before.comped, "to" => updated.comped}
    })

    ok
  end

  defp audit_comp(other, _before, _action, _opts), do: other

  @doc """
  The Stripe Customer for `user`, created on first need. Checkout must never
  be opened without one: passing `customer_email` instead makes Stripe mint
  its own Customer whose id we never learn.
  """
  @spec ensure_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_stripe_customer(%User{stripe_customer_id: id} = user)
      when is_binary(id) and id != "",
      do: {:ok, user}

  def ensure_stripe_customer(%User{} = user), do: create_stripe_customer(user)

  # ─── Stripe webhooks ────────────────────────────────────────────────────────

  @doc """
  Claim a verified Stripe event once (`stripe_events`) and apply it inside the
  same transaction, so a failed apply leaves the event unclaimed for Stripe to
  redeliver. Returns `{:ok, :duplicate}` for an event already seen.
  """
  @spec handle_event(Stripe.Event.t()) ::
          {:ok, :ignored | :duplicate | :credits_purchased | :credits_clawed_back}
          | {:error, term()}
  def handle_event(%Stripe.Event{id: id, type: type} = event) when is_binary(id) do
    Repo.transaction(fn ->
      if claim_event(id, type) == :claimed do
        case apply_event(event) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        :duplicate
      end
    end)
  end

  # No id (hand-built events in tests) — nothing to dedupe against.
  def handle_event(%Stripe.Event{} = event), do: apply_event(event)

  @doc """
  Best-effort record of a webhook processing failure (#501).

  A failed apply rolls the `stripe_events` claim back by design, so without
  this a failing event leaves zero DB trace — the failure exists only in
  Stripe's dashboard and our logs, and a purchase or a clawback silently
  never reaches the ledger. One row per event id: a retried delivery bumps `failure_count`
  and `last_failed_at` (and un-resolves a previously resolved row) rather
  than accumulating a row per attempt across Stripe's three days of retries.

  Best-effort on the same contract as `record_usage/5`: recording the
  failure must never change the webhook response.
  """
  @spec record_webhook_failure(Stripe.Event.t(), term()) :: :ok | :error
  def record_webhook_failure(%Stripe.Event{id: id, type: type}, reason) when is_binary(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    error = reason |> inspect() |> String.slice(0, 500)

    Repo.insert_all(
      "stripe_webhook_failures",
      [
        %{
          event_id: id,
          event_type: type,
          error: error,
          failure_count: 1,
          first_failed_at: now,
          last_failed_at: now
        }
      ],
      on_conflict: [
        set: [error: error, last_failed_at: now, resolved_at: nil],
        inc: [failure_count: 1]
      ],
      conflict_target: :event_id
    )

    :ok
  rescue
    e ->
      Logger.error(
        "webhook failure record failed for #{inspect(reason)}: #{Exception.message(e)}"
      )

      :error
  end

  def record_webhook_failure(_event, _reason), do: :ok

  @doc """
  Marks a previously recorded webhook failure resolved — called when a later
  delivery of the same event processes successfully (or dedupes/goes stale,
  which means the event no longer needs applying). Best-effort, like
  `record_webhook_failure/2`.
  """
  @spec resolve_webhook_failure(String.t() | nil) :: :ok
  def resolve_webhook_failure(event_id) when is_binary(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(f in "stripe_webhook_failures",
        where: f.event_id == ^event_id and is_nil(f.resolved_at)
      ),
      set: [resolved_at: now]
    )

    :ok
  rescue
    e ->
      Logger.error("webhook failure resolve failed for #{event_id}: #{Exception.message(e)}")
      :ok
  end

  def resolve_webhook_failure(_), do: :ok

  # Atomic claim: the unique primary key is what makes concurrent deliveries of
  # the same event resolve to exactly one winner.
  defp claim_event(id, type) do
    {count, _} =
      Repo.insert_all(
        "stripe_events",
        [
          %{
            id: id,
            type: type,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ],
        on_conflict: :nothing
      )

    if count == 1, do: :claimed, else: :duplicate
  end

  @doc """
  Apply one verified Stripe event to the credit ledger (ADR 0031). Three
  event types matter, all handled by `Fountain.Credits.Purchases`:
  `checkout.session.completed` for a credit pack, `charge.refunded` and
  `charge.dispute.created` for the clawbacks. Everything else returns
  `{:ok, :ignored}` without touching the database.
  """
  @spec apply_event(Stripe.Event.t()) ::
          {:ok, :ignored | :credits_purchased | :credits_clawed_back} | {:error, term()}
  def apply_event(%Stripe.Event{
        type: "checkout.session.completed",
        data: %{object: session}
      }) do
    # Only a credit pack (ADR 0031): a session Fountain did not open for
    # credits is somebody else's, acknowledged and ignored.
    if Fountain.Credits.Purchases.credits_session?(session) do
      case Fountain.Credits.Purchases.complete(session) do
        {:ok, _entry} -> {:ok, :credits_purchased}
        {:ok, :duplicate, _entry} -> {:ok, :credits_purchased}
        {:error, :user_not_found} -> {:error, :user_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :ignored}
    end
  end

  # charge.refunded and charge.dispute.created only matter for a credit pack
  # (ADR 0030 decision 5). Neither names a customer we need to look up: the
  # purchase row does.
  def apply_event(%Stripe.Event{type: "charge.refunded", data: %{object: charge}}) do
    case Fountain.Credits.Purchases.refund(charge) do
      {:ok, :nothing} -> {:ok, :ignored}
      {:ok, _entry} -> {:ok, :credits_clawed_back}
      {:ok, :duplicate, _} -> {:ok, :credits_clawed_back}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_event(%Stripe.Event{type: "charge.dispute.created", data: %{object: dispute}}) do
    case Fountain.Credits.Purchases.dispute(dispute) do
      {:ok, :nothing} -> {:ok, :ignored}
      {:ok, _entry} -> {:ok, :credits_clawed_back}
      {:ok, :duplicate, _} -> {:ok, :credits_clawed_back}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_event(_event), do: {:ok, :ignored}

  @doc """
  `Fountain.Usage.usage_summary/3` plus `:credit_burned_cents`, what the
  ledger took for the window — for the credits page and API.
  """
  @spec usage_summary(binary(), DateTime.t(), DateTime.t()) :: map()
  def usage_summary(user_id, %DateTime{} = period_start, %DateTime{} = period_end) do
    user_id
    |> Fountain.Usage.usage_summary(period_start, period_end)
    |> Map.put(
      :credit_burned_cents,
      Fountain.Credits.burned_between(user_id, period_start, period_end)
    )
  end

  # ─── Admin billing overview (#286) ──────────────────────────────────────────

  @doc """
  The numbers an operator checks daily, in one read-only pass — for the admin
  panel (no tenant scoping; the caller is behind `require_admin`).

  - `funded` — accounts with a positive credit balance
  - `deferred_cents` — the sum of every positive balance: credit granted or
    sold and not yet spent
  - `purchases_this_month` — `checkout.session.completed` webhook events
    since the start of the current UTC month. Every verified webhook is
    claimed into `stripe_events` before handling, so the claim table is a
    complete record of checkouts.
  - `webhook_failures` — unresolved rows from `record_webhook_failure/2`

  Read the function for the exact keys; they are what `/admin` renders.
  """
  def overview_admin(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event_limit = Keyword.get(opts, :event_limit, 10)

    accounts = from(u in User)

    comped = Repo.one(from(u in accounts, where: u.comped, select: count(u.id))) || 0
    total = Repo.one(from(u in accounts, select: count(u.id))) || 0

    funded =
      Repo.one(from(u in accounts, where: u.credit_balance_cents > 0, select: count(u.id))) || 0

    deferred = Fountain.Billing.Finance.deferred_cents()
    %{start: month_start} = Fountain.Usage.month_range(0, now: now)

    purchases_this_month =
      Repo.one(
        from e in Fountain.Credits.LedgerEntry,
          where: e.reason == "purchase" and e.inserted_at >= ^month_start,
          select: count(e.id)
      ) || 0

    recent_events =
      Repo.all(
        from e in "stripe_events",
          order_by: [desc: e.inserted_at],
          limit: ^event_limit,
          select: %{id: e.id, type: e.type, inserted_at: e.inserted_at}
      )

    failed_events =
      Repo.all(
        from f in "stripe_webhook_failures",
          where: is_nil(f.resolved_at),
          order_by: [desc: f.last_failed_at],
          limit: ^event_limit,
          select: %{
            event_id: f.event_id,
            event_type: f.event_type,
            error: f.error,
            failure_count: f.failure_count,
            last_failed_at: f.last_failed_at
          }
      )

    %{
      accounts: total,
      comped: comped,
      funded: funded,
      deferred_cents: deferred,
      purchases_this_month: purchases_this_month,
      recent_events: recent_events,
      failed_events: failed_events
    }
  end

  # ─── Private helpers ────────────────────────────────────────────────────────
end
