defmodule Fountain.Repo.Migrations.CreateChatgptLinkAttempts do
  use Ecto.Migration

  # ADR 0060 stage 4 (0052 decision 2): one row per device-code sign-in a
  # user has begun, for a new subscription or for a reconnect of one grant.
  # The row is the whole of the attempt's state, so a page reload, an API
  # poll and the job that drives it all read the same thing and no process
  # holds any of it.
  #
  #   * `grant_id`, `expected_generation` -- a reconnect's target and the
  #     generation it began against, pinned by the server when the attempt is
  #     created. No foreign key, for the reason `broker_sessions` has none: a
  #     grant removed under an open attempt must make the attempt fail by
  #     name, not take the row away from under whoever is polling it.
  #   * `name` -- a new link's name. Exactly one of `name` and `grant_id`.
  #   * `device_auth_ciphertext`, `user_code_ciphertext` -- what the auth
  #     server handed back, under the owner's DEK. Present while the attempt
  #     is `pending` and dropped by the write that ends it, which the check
  #     below holds: a finished attempt has nothing left to exchange.
  #   * `poll_interval` -- the seconds between polls the auth server asked
  #     for. `poll_failures` -- consecutive polls it did not answer, which is
  #     what the job backs off on.
  #   * `result_grant_id` -- the grant a completed attempt wrote.
  #     `conflict_grant_id` -- for `account_already_linked`, the grant that
  #     already holds the account, so the answer can say which to reconnect.
  #
  # `chatgpt_link_attempts_open_reconnect` is one open reconnect per grant.
  # The context refuses the second by id before the index can; the index is
  # the backstop.
  #
  # `up` and `down`, not `change`: a reversed `change` runs its statements
  # last to first, so the `lock_timeout` would be set after the drop it is
  # there for.
  def up do
    # The reference takes a lock on `users`; do not queue behind a long one.
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:chatgpt_link_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :grant_id, :binary_id
      add :expected_generation, :binary_id
      add :name, :string
      add :device_auth_ciphertext, :binary
      add :user_code_ciphertext, :binary
      add :verification_url, :string, null: false
      add :poll_interval, :integer, null: false
      add :poll_failures, :integer, null: false, default: 0
      add :state, :string, null: false, default: "pending"
      add :failure_reason, :string
      add :result_grant_id, :binary_id
      add :conflict_grant_id, :binary_id
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chatgpt_link_attempts, [:user_id, :state])

    # The starts an account made in the last hour are counted on every start.
    create index(:chatgpt_link_attempts, [:user_id, :inserted_at])

    create unique_index(:chatgpt_link_attempts, [:grant_id],
             where: "state = 'pending'",
             name: :chatgpt_link_attempts_open_reconnect
           )

    create constraint(:chatgpt_link_attempts, :chatgpt_link_attempt_state,
             check: "state IN ('pending', 'completed', 'cancelled', 'expired', 'failed')"
           )

    create constraint(:chatgpt_link_attempts, :chatgpt_link_attempt_target,
             check:
               "(name IS NULL) <> (grant_id IS NULL) AND " <>
                 "(grant_id IS NULL) = (expected_generation IS NULL)"
           )

    create constraint(:chatgpt_link_attempts, :chatgpt_link_attempt_secrets_follow_state,
             check:
               "(state = 'pending') = (device_auth_ciphertext IS NOT NULL) AND " <>
                 "(state = 'pending') = (user_code_ciphertext IS NOT NULL)"
           )

    create constraint(:chatgpt_link_attempts, :chatgpt_link_attempt_outcome,
             check:
               "(state = 'failed') = (failure_reason IS NOT NULL) AND " <>
                 "(state = 'completed') = (result_grant_id IS NOT NULL) AND " <>
                 "(conflict_grant_id IS NULL OR state = 'failed')"
           )

    create constraint(:chatgpt_link_attempts, :chatgpt_link_attempt_poll_interval,
             check: "poll_interval >= 1"
           )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    drop table(:chatgpt_link_attempts)
  end
end
