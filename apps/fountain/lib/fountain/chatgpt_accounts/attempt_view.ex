defmodule Fountain.ChatGPTAccounts.AttemptView do
  @moduledoc """
  One link attempt as its owner may see it
  (`Fountain.ChatGPTAccounts.get_attempt_for_user/2`).

  `:kind` is `:link` for a new subscription, which carries the `:name` it
  will take, and `:reconnect` for a sign-in over one grant, which carries
  that `:grant_id`. `:state` is what the row says, except that a pending row
  past its `:expires_at` reads `"expired"` whether or not anything has
  written that yet.

  `:user_code` and `:verification_url` are what the owner types and where,
  and are set only while the attempt is pending; both are nil once it has
  ended. The user code is the one decrypted value here, so `inspect/1` leaves
  it out: a view that reaches a log line or a crash report does not carry the
  code. The auth server's `device_auth_id`, the pinned generation and every
  token are not fields at all.

  `:result_grant_id` is the grant a completed attempt wrote. `:failure` is
  nil or `%{reason: _, grant_id: _, grant: _}`: `reason` is one of
  `Fountain.ChatGPTAccounts.LinkAttempt.failure_reasons/0`, and for
  `"account_already_linked"` the other two name the grant that already
  holds the account, which is the one to reconnect.
  """

  @derive {Inspect, except: [:user_code]}
  defstruct [
    :id,
    :kind,
    :name,
    :grant_id,
    :state,
    :user_code,
    :verification_url,
    :poll_interval,
    :expires_at,
    :result_grant_id,
    :failure,
    :inserted_at,
    :updated_at
  ]

  @type failure :: %{
          reason: String.t(),
          grant_id: Ecto.UUID.t() | nil,
          grant: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          kind: :link | :reconnect,
          name: String.t() | nil,
          grant_id: Ecto.UUID.t() | nil,
          state: String.t(),
          user_code: String.t() | nil,
          verification_url: String.t() | nil,
          poll_interval: pos_integer(),
          expires_at: DateTime.t(),
          result_grant_id: Ecto.UUID.t() | nil,
          failure: failure() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
