defmodule Fountain.Repo.Migrations.AddClientRequestIdToTurns do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # The caller's correlation for the prompt that opened this turn (#1406). A
    # prompt is accepted before its turn exists whenever the conversation has
    # to be woken first, so the response cannot name the turn; the caller names
    # the request instead, and the turn carries that name once it is opened.
    #
    # Additive and nullable: a replica on the previous release neither writes
    # nor reads it, and `nil` is "the caller sent none", which is every row on
    # the way in and every autonomous turn afterwards.
    #
    # No index, and not unique. Nothing looks a turn up by this value: it is
    # read as a column of turns already selected by conversation. It is a
    # correlation, not an idempotency key, so two turns may carry the same one.
    alter table(:turns) do
      add :client_request_id, :string
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:turns) do
      remove :client_request_id
    end
  end
end
