defmodule Fountain.ChatGPTAccounts.LinkAttempt do
  @moduledoc """
  One device-code sign-in a user has begun: for a new subscription (`name`)
  or for a reconnect of one grant (`grant_id`, with the `expected_generation`
  the server pinned when the attempt began). ADR 0060 decision 3, which
  carries 0052 decision 2's attempt rules: short-lived, owner-bound,
  single-use, an opaque id, exchange secrets encrypted, completion rechecked.

  The row is the attempt's whole state. Nothing holds any of it in memory:
  a page reload, an API poll and `Fountain.Workers.ChatGPTLinkAttempt` all
  read this row, scoped by its owner.

  `state` is `"pending"` and then exactly one of `"completed"`,
  `"cancelled"`, `"expired"` and `"failed"`, all terminal. A pending row past
  its `expires_at` is expired whether or not anything has written that yet:
  `expired?/2` is what a reader asks, and no write admits such a row.

  `device_auth_ciphertext` and `user_code_ciphertext` are what the auth
  server handed back, under the owner's DEK with an AAD naming the owner,
  the attempt and the field (`Fountain.ChatGPTAccounts.Cipher`). Both are
  `redact: true`, and `finish_changeset/3` drops both: a finished attempt has
  nothing left to exchange (`chatgpt_link_attempt_secrets_follow_state`).
  There is no plaintext column, and no token is ever stored here: the
  exchange's tokens go from the auth server into the grant row and nowhere
  else.

  `failure_reason` is one of `failure_reasons/0`, never anything the auth
  server said. `conflict_grant_id` names, for `"account_already_linked"`, the
  grant that already holds the account; `result_grant_id` the grant a
  completed attempt wrote.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.PlatformChatGPT.Account

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(pending completed cancelled expired failed)

  @failure_reasons ~w(
    stale_grant
    account_already_linked
    grant_limit_reached
    grant_not_found
    name_taken
    owner_ineligible
    tenant_key_unavailable
    invalid_sign_in
    authorization_failed
    exchange_failed
  )

  @type t :: %__MODULE__{}

  schema "chatgpt_link_attempts" do
    field :grant_id, :binary_id
    field :expected_generation, Ecto.UUID
    field :name, :string
    field :device_auth_ciphertext, :binary, redact: true
    field :user_code_ciphertext, :binary, redact: true
    field :verification_url, :string
    field :poll_interval, :integer
    field :poll_failures, :integer, default: 0
    field :state, :string, default: "pending"
    field :failure_reason, :string
    field :result_grant_id, :binary_id
    field :conflict_grant_id, :binary_id
    field :expires_at, :utc_datetime

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def failure_reasons, do: @failure_reasons

  @doc """
  A new attempt, on a struct that already carries its id and its owner: the
  secrets are encrypted to both before the row exists. Neither is cast.
  """
  def start_changeset(%__MODULE__{id: id, user_id: user_id} = attempt, attrs)
      when is_binary(id) and is_binary(user_id) do
    attempt
    |> cast(attrs, [
      :grant_id,
      :expected_generation,
      :name,
      :device_auth_ciphertext,
      :user_code_ciphertext,
      :verification_url,
      :poll_interval,
      :expires_at
    ])
    |> validate_required([
      :device_auth_ciphertext,
      :user_code_ciphertext,
      :verification_url,
      :poll_interval,
      :expires_at
    ])
    |> validate_number(:poll_interval, greater_than_or_equal_to: 1)
    |> target_rules()
    |> unique_constraint(:grant_id,
      name: :chatgpt_link_attempts_open_reconnect,
      message: "already has a sign-in in progress"
    )
    |> check_constraint(:name,
      name: :chatgpt_link_attempt_target,
      message: "give a name or a grant, not both"
    )
  end

  @doc """
  The name a new link would take, held to the grant's own rule
  (`Account.name_format/1`) and nothing else, so a bad one is refused before
  the auth server is asked for a code.
  """
  def name_changeset(name) do
    %__MODULE__{}
    |> cast(%{name: name}, [:name])
    |> Account.name_format()
  end

  @doc """
  The write that ends an attempt. It drops both secrets whatever the state,
  and is only ever applied to a row its caller holds locked and has seen
  `pending`.
  """
  def finish_changeset(%__MODULE__{state: "pending"} = attempt, state, attrs \\ %{})
      when state in ~w(completed cancelled expired failed) do
    attempt
    |> cast(attrs, [:failure_reason, :result_grant_id, :conflict_grant_id])
    |> change(state: state, device_auth_ciphertext: nil, user_code_ciphertext: nil)
    |> validate_inclusion(:failure_reason, @failure_reasons)
    |> check_constraint(:state, name: :chatgpt_link_attempt_outcome)
  end

  @doc "Whether a row still reading `pending` has run out of time."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{state: "pending", expires_at: at}, %DateTime{} = now),
    do: DateTime.compare(at, now) != :gt

  def expired?(%__MODULE__{}, _now), do: false

  # A reconnect carries no name and a link no grant; a name follows the
  # grant's own format.
  defp target_rules(changeset) do
    case {get_field(changeset, :grant_id), get_field(changeset, :name)} do
      {nil, _name} ->
        Account.name_format(changeset)

      {_grant_id, nil} ->
        validate_required(changeset, [:expected_generation])

      {_grant_id, _name} ->
        add_error(changeset, :name, "give a name or a grant, not both")
    end
  end
end
