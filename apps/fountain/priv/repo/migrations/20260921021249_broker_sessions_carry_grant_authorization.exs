defmodule Fountain.Repo.Migrations.BrokerSessionsCarryGrantAuthorization do
  use Ecto.Migration

  # ADR 0052 decision 5, built by ADR 0060 stage 3: a broker session that may
  # use a managed ChatGPT grant says which one, as server-controlled
  # authorization data and not as a rule.
  #
  # Plain columns, outside `rules_ciphertext`, because the proxy's per-request
  # check reads them and the grant's own transaction writes one of them:
  #
  #   * `managed_grant_id`, `managed_grant_generation` -- the pin. A session is
  #     authority for exactly that sign-in of that grant. No foreign key, on
  #     purpose: a grant that is gone must deny, not cascade the session away
  #     under a conversation whose other egress is still good, and an id is
  #     never reused.
  #   * `managed_grant_owner_id` -- the owning user, NULL for the deployment's
  #     grant. A user's grant rides only that user's own session, which the
  #     check below holds in the database.
  #   * `managed_identity` -- the ChatGPT account id the session was issued
  #     for. Not a secret (codex sends it in the clear). The proxy pins it as
  #     the identity header, and a request is admitted only while the grant
  #     row still names the same account.
  #   * `managed_revoked_at` -- set by the grant's disconnect, replacement or
  #     revocation, in that same transaction. It is the fast path. The
  #     authority is the join to the grant row's generation and status on
  #     every request, which denies whether or not this was ever written.
  #
  # All NULL on every existing row and on every session that carries no
  # managed grant, which stays a lookup-only session as before.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:broker_sessions) do
      add :managed_grant_id, :binary_id
      add :managed_grant_generation, :binary_id
      add :managed_grant_owner_id, :binary_id
      add :managed_identity, :string
      add :managed_revoked_at, :utc_datetime_usec
    end

    create index(:broker_sessions, [:managed_grant_id], where: "managed_grant_id IS NOT NULL")

    create constraint(:broker_sessions, :managed_grant_complete,
             check:
               "(managed_grant_id IS NULL) = (managed_grant_generation IS NULL) AND " <>
                 "(managed_grant_id IS NULL) = (managed_identity IS NULL) AND " <>
                 "(managed_grant_id IS NOT NULL OR " <>
                 "(managed_grant_owner_id IS NULL AND managed_revoked_at IS NULL))"
           )

    create constraint(:broker_sessions, :managed_grant_owner_is_session_owner,
             check: "managed_grant_owner_id IS NULL OR managed_grant_owner_id = user_id"
           )
  end

  # A session that carries a managed grant is authority only through these
  # columns; without them it would read as an ordinary lookup-only session
  # with no way to reach the grant at all, so it is deleted rather than kept.
  # Its conversation mints a new one on its next turn.
  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("DELETE FROM broker_sessions WHERE managed_grant_id IS NOT NULL")

    drop constraint(:broker_sessions, :managed_grant_owner_is_session_owner)
    drop constraint(:broker_sessions, :managed_grant_complete)
    drop index(:broker_sessions, [:managed_grant_id])

    alter table(:broker_sessions) do
      remove :managed_grant_id
      remove :managed_grant_generation
      remove :managed_grant_owner_id
      remove :managed_identity
      remove :managed_revoked_at
    end
  end
end
