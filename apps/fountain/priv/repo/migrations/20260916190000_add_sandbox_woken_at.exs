defmodule Fountain.Repo.Migrations.AddSandboxWokenAt do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # The wake-registration marker (ADR 0058 stage 6a, #2307 constraint 4).
    # Horde's registry is an asynchronous CRDT, so "no live server" read on one
    # node is not evidence that none was started on another. A starter commits
    # this timestamp under the per-sandbox advisory lock *before* it asks Horde
    # for a child, which makes the registration a database fact every node sees
    # the instant the transaction commits. The reaper's two liveness passes
    # honour a fresh one as a grace condition beside `updated_at`.
    #
    # Additive and nullable: a replica on the previous release neither writes
    # nor reads it, and `nil` is exactly "never woken", which is how every row
    # reads on the way in.
    #
    # No index. It is read as a column of a row the two reaper sweeps have
    # already selected by status and fence, never scanned for.
    alter table(:sandboxes) do
      add :woken_at, :utc_datetime_usec
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Only `Fountain.Conversations.register_server/2` writes it and only the
    # reaper reads it; dropping it restores the pre-6a grace, which is
    # `updated_at` alone.
    alter table(:sandboxes) do
      remove :woken_at
    end
  end
end
