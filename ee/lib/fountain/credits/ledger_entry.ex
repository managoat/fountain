defmodule Fountain.Credits.LedgerEntry do
  @moduledoc """
  One row of the credit ledger (ADR 0030).

  Append-only. `amount_cents` is signed: positive rows put money in
  (a grant, a purchase), negative rows take it out (a burn, an expiry, a
  clawback). `reason` is a closed vocabulary — see `Fountain.Credits` — and
  `idempotency_key` is unique, which is what makes every writer safe to
  retry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_ledger" do
    field :amount_cents, :integer
    field :reason, :string
    field :resource_type, :string
    field :resource_id, :string
    field :idempotency_key, :string
    field :expires_at, :utc_datetime
    # How much of a credit row is still unspent (a lot). Nil on debit rows.
    # Written only by `Fountain.Credits`, in the same transaction as the row
    # that consumed it.
    field :remaining_cents, :integer
    # Insertion order, assigned by the database.
    field :seq, :integer, read_after_writes: true
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime

    belongs_to :user, Fountain.Accounts.User
  end

  # `grant_application` is money an application moved into a claimable
  # principal it opened (ADR 0044), and the same reason carries the refund
  # back to the application when an unclaimed principal is released or
  # expires. `burn_grant` is the application paying for it: the two are one
  # transfer, written as two rows because a tenant's ledger only ever
  # describes its own side of it.
  @credit_reasons ~w(grant_opening grant_admin grant_application purchase)
  # `burn_inference` is tokens a turn spent on a **platform** inference key
  # (#1388), priced at the provider's list price by
  # `Fountain.Credits.InferenceRates`. A turn on the tenant's own credential
  # burns none of it — Fountain paid nothing — so it sits beside `burn_turn`
  # rather than inside it.
  @debit_reasons ~w(burn_turn burn_inference burn_grant expire clawback_refund clawback_dispute)

  @doc "Reasons that put money in. Every one is a positive row."
  def credit_reasons, do: @credit_reasons

  @doc "Reasons that take money out. Every one is a negative row."
  def debit_reasons, do: @debit_reasons

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :user_id,
      :amount_cents,
      :reason,
      :resource_type,
      :resource_id,
      :idempotency_key,
      :expires_at,
      :metadata
    ])
    |> validate_required([:user_id, :amount_cents, :reason, :idempotency_key])
    |> validate_inclusion(:reason, @credit_reasons ++ @debit_reasons)
    |> validate_sign()
    |> validate_length(:idempotency_key, max: 255)
    |> put_change(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:user_id)
  end

  # The sign is implied by the reason, so a caller cannot write a negative
  # grant or a positive burn by passing the wrong number.
  defp validate_sign(changeset) do
    reason = get_field(changeset, :reason)
    amount = get_field(changeset, :amount_cents)

    cond do
      is_nil(reason) or is_nil(amount) ->
        changeset

      amount == 0 ->
        add_error(changeset, :amount_cents, "must not be zero")

      reason in @credit_reasons and amount < 0 ->
        add_error(changeset, :amount_cents, "a credit must be positive")

      reason in @debit_reasons and amount > 0 ->
        add_error(changeset, :amount_cents, "a debit must be negative")

      true ->
        changeset
    end
  end
end
