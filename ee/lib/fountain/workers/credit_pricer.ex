defmodule Fountain.Workers.CreditPricer do
  @moduledoc """
  Prices what a tenant used into the credit ledger (ADR 0030 decision 3).

  Two passes, both idempotent, both bounded by a seven-day look-back:

    * **Turns.** Every closed turn (`ended_at` set) on a provider Fountain pays
      for burns `Credits.turn_cost_cents(ended - started)` under the key
      `burn_turn:<turn_id>`. A turn is priced once, when it closes: an
      in-flight turn that crosses zero finishes and lands as debt, which is
      the soft stop of decision 6. Runner turns cost Fountain nothing and burn
      nothing (ADR 0022); a turn with no sandbox never ran.
    * **Inference.** Every closed turn that ran on a **platform** inference
      key (#1388) burns `Credits.InferenceRates.cost_cents/1` of its
      `turns.usage` under the key `burn_inference:<turn_id>`. Unlike the turn
      pass this one does **not** filter on the sandbox provider: a
      self-hosted runner costs Fountain no sandbox time but its tokens are
      still on Fountain's key. A turn on the tenant's own credential is not
      marked and is never seen here.

  Rows are written for every tenant, comped included: the ledger is also how
  `Finance` sees what a comp cost. Refusing spend is `Credits.gate/1`'s job,
  behind `Billing.check_spend/1`; this worker only writes what happened.

  Every tick also runs the expiry pass (`Workers.CreditExpirer.run/1`), so a
  grant past its date is swept within ten minutes rather than at the daily
  06:23 sweep; the gate already ignores an expired lot in the meantime.

  No-ops when billing is off. The look-back is seven days, so a restart after an
  outage catches up without scanning the whole table; a turn older than that
  which somehow escaped pricing is a reconciliation job, not this one's.

  Rounding is to the nearest cent per turn. A one-minute turn at $0.25/hour is
  0.4 cents and burns nothing; the error is symmetric and averages out, and a
  ledger of fractional cents is a ledger nobody can reconcile.
  """

  use Oban.Worker, queue: :credits, max_attempts: 3, unique: [period: 60]

  import Ecto.Query

  alias Fountain.Billing.SandboxUsage
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Turn
  alias Fountain.Credits
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  require Logger

  @lookback_days 7
  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    counts = run()
    Fountain.Credits.Telemetry.emit_run("pricer", counts)

    case counts do
      %{turns: 0, inference: 0, expired: 0} ->
        :ok

      counts ->
        Logger.info(
          "credit pricer: burned #{counts.turns} turns, #{counts.inference} platform-inference " <>
            "turns, expired #{counts.expired} grants"
        )
    end

    :ok
  end

  @doc """
  Run every pass now. `:now` pins the clock; `:since` overrides the
  configured floor. Returns `%{turns: n, inference: n, expired: n}` — rows
  written, not rows seen.
  """
  @spec run(keyword()) :: %{
          turns: non_neg_integer(),
          inference: non_neg_integer(),
          expired: non_neg_integer()
        }
  def run(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    lookback = DateTime.add(now, -@lookback_days * 86_400, :second)

    # `:since` is a test override that can only narrow the window.
    floor =
      case Keyword.get(opts, :since) do
        %DateTime{} = since ->
          if DateTime.compare(since, lookback) == :gt, do: since, else: lookback

        nil ->
          lookback
      end

    if Credits.enabled?(),
      do: do_run(floor, now),
      else: %{turns: 0, inference: 0, expired: 0}
  end

  defp do_run(floor, now) do
    {turns, touched} = price_turns(floor)
    {inference, inference_touched} = price_inference(floor)

    touched
    |> MapSet.new()
    |> MapSet.union(MapSet.new(inference_touched))
    |> Enum.each(&Fountain.Workers.CreditsEmail.notify_after_burn/1)

    # Burns first, so a turn consumes the grant before the grant is swept.
    %{expired: expired} = Fountain.Workers.CreditExpirer.run(now: now)
    %{turns: turns, inference: inference, expired: expired}
  end

  # ---------------------------------------------------------------------------
  # Turns
  # ---------------------------------------------------------------------------

  # Returns `{rows_written, user_ids_touched}`; the second is who to warn.
  defp price_turns(floor), do: price_turns(floor, 0, MapSet.new())

  defp price_turns(floor, written, touched) do
    case unpriced_turns(floor) do
      [] ->
        {written, MapSet.to_list(touched)}

      turns ->
        priced = Enum.filter(turns, &price_turn/1)
        n = length(priced)
        touched = Enum.reduce(priced, touched, &MapSet.put(&2, &1.user_id))
        # The anti-join hides what was just written, so the next page is the
        # next unpriced batch. A page that wrote nothing (every turn was free,
        # or a duplicate) would loop forever; stop on it.
        if n == 0 or length(turns) < @batch,
          do: {written + n, MapSet.to_list(touched)},
          else: price_turns(floor, written + n, touched)
    end
  end

  defp unpriced_turns(floor) do
    providers = SandboxUsage.platform_paid_providers()

    from(t in Turn,
      join: c in Conversation,
      on: c.id == t.conversation_id,
      join: s in Sandbox,
      on: s.id == c.sandbox_id,
      left_join: l in LedgerEntry,
      on: l.idempotency_key == fragment("'burn_turn:' || ?::text", t.id),
      where: is_nil(l.id),
      where: not is_nil(t.started_at) and not is_nil(t.ended_at),
      where: is_nil(t.orphaned_at),
      where: t.ended_at >= ^floor,
      where: s.provider in ^providers,
      where: not is_nil(c.user_id),
      order_by: [asc: t.ended_at],
      limit: @batch,
      select: %{
        id: t.id,
        user_id: c.user_id,
        conversation_id: c.id,
        provider: s.provider,
        started_at: t.started_at,
        ended_at: t.ended_at
      }
    )
    |> Repo.all()
  end

  # True when a row was written. A turn that rounds to nothing is not written
  # at all, so it will be seen again next run and skipped again; that costs
  # one anti-join row per free turn per run, and the look-back bounds it.
  defp price_turn(turn) do
    seconds = max(DateTime.diff(turn.ended_at, turn.started_at, :second), 0)

    case Credits.turn_cost_cents(seconds) do
      0 ->
        false

      cents ->
        case Credits.debit(payer(turn.user_id), cents, "burn_turn",
               idempotency_key: "burn_turn:#{turn.id}",
               resource_type: "turn",
               resource_id: turn.id,
               actor: "system:credit_pricer",
               metadata: %{
                 "turn_seconds" => seconds,
                 "provider" => turn.provider,
                 "conversation_id" => turn.conversation_id
               }
             ) do
          {:ok, _} ->
            true

          {:ok, :duplicate, _} ->
            false

          {:error, reason} ->
            Logger.warning("credit pricer: turn #{turn.id} not priced: #{inspect(reason)}")
            false
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Platform inference (#1388)
  # ---------------------------------------------------------------------------

  # Same shape as the turn pass: `{rows_written, user_ids_touched}`.
  defp price_inference(floor), do: price_inference(floor, 0, MapSet.new())

  defp price_inference(floor, written, touched) do
    case unpriced_inference_turns(floor) do
      [] ->
        {written, MapSet.to_list(touched)}

      turns ->
        priced = Enum.filter(turns, &price_inference_turn/1)
        n = length(priced)
        touched = Enum.reduce(priced, touched, &MapSet.put(&2, &1.user_id))

        if n == 0 or length(turns) < @batch,
          do: {written + n, MapSet.to_list(touched)},
          else: price_inference(floor, written + n, touched)
    end
  end

  # No join to `sandboxes` and no provider filter, unlike `unpriced_turns/1`:
  # the sandbox provider says who paid for the *machine*, and this pass is
  # about who paid for the *tokens*. A turn on a tenant's own runner
  # (ADR 0022) costs Fountain no sandbox time and still spends Fountain's
  # inference key when the tenant has none of their own.
  #
  # `usage ->> 'inference' = 'platform'` is the source selector: the
  # ConversationServer stamps that key only on a turn whose credentials came
  # from `Fountain.PlatformInference`, so a deployment that holds no platform
  # key has no matching row and this query is a cheap miss.
  #
  # A turn figure has to be there too. Since #1685 the stamp is written at
  # turn start, so a platform turn that never answered its prompt — an
  # adapter exit, a sandbox deadline, a restart, an interrupt — carries the
  # source with no token count. `cost_cents/1` prices such a row at zero and
  # writes no ledger row, and *that* is still the behaviour: what a turn with
  # unknown tokens should cost has not been decided (#1685 follow-up).
  #
  # `jsonb_typeof` before anything else, for the reason `Conversations`
  # gives over the same column: `usage` is whatever the runtime reported, and
  # nothing validates its shape on the way in.
  #
  # It is excluded from the page rather than filtered out of it because the
  # pass stops on a page that wrote nothing. Those turns outnumber the
  # answered ones by better than ten to one in production, so leaving them in
  # would let a full page of unpriceable rows hold the cursor still and starve
  # the priceable turns behind them — a worse billing bug than the one the
  # stamp fixes. The rows are on disk and queryable by the same selector when
  # the pricing decision lands.
  defp unpriced_inference_turns(floor) do
    from(t in Turn,
      join: c in Conversation,
      on: c.id == t.conversation_id,
      left_join: l in LedgerEntry,
      on: l.idempotency_key == fragment("'burn_inference:' || ?::text", t.id),
      where: is_nil(l.id),
      where: not is_nil(t.ended_at),
      where: t.ended_at >= ^floor,
      where: fragment("? ->> 'inference' = 'platform'", t.usage),
      where:
        fragment(
          "(jsonb_typeof(? -> 'input') = 'number' or jsonb_typeof(? -> 'output') = 'number' or jsonb_typeof(? -> 'cache_read') = 'number' or jsonb_typeof(? -> 'cache_write') = 'number')",
          t.usage,
          t.usage,
          t.usage,
          t.usage
        ),
      where: not is_nil(c.user_id),
      order_by: [asc: t.ended_at],
      limit: @batch,
      select: %{
        id: t.id,
        user_id: c.user_id,
        conversation_id: c.id,
        usage: t.usage
      }
    )
    |> Repo.all()
  end

  # True when a row was written. A turn whose tokens round to nothing writes
  # none, and is skipped again next run — the same trade `price_turn/1` makes.
  defp price_inference_turn(turn) do
    case Credits.InferenceRates.cost_cents(turn.usage) do
      0 ->
        false

      cents ->
        case Credits.debit(payer(turn.user_id), cents, "burn_inference",
               idempotency_key: "burn_inference:#{turn.id}",
               resource_type: "turn",
               resource_id: turn.id,
               actor: "system:credit_pricer",
               # Tokens and a model id, not a prompt and not a reply: the
               # ledger is not a second copy of the transcript.
               metadata: %{
                 "model" => turn.usage["model"],
                 "input" => turn.usage["input"],
                 "output" => turn.usage["output"],
                 "conversation_id" => turn.conversation_id
               }
             ) do
          {:ok, _} ->
            true

          {:ok, :duplicate, _} ->
            false

          {:error, reason} ->
            Logger.warning(
              "credit pricer: turn #{turn.id} inference not priced: #{inspect(reason)}"
            )

            false
        end
    end
  end

  # Whose ledger the burn lands on (ADR 0044). The work is the principal's and
  # every `resource_id` here still names it; only the money follows the account
  # that claimed it, so usage before and after a claim is charged to the right
  # side without a single ledger row ever moving.
  defp payer(user_id), do: Fountain.Principals.billing_subject_id(user_id)
end
