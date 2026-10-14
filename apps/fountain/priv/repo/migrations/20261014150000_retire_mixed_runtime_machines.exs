defmodule Fountain.Repo.Migrations.RetireMixedRuntimeMachines do
  use Ecto.Migration

  require Logger

  # Mixed-runtime guests are removed (#2676; ADR 0023's 2026-09-26 amendment
  # is reversed). This release no longer registers a co-tenant's inference
  # credential for redaction (`CotenantSecrets` is gone), so no machine that
  # ever carried a conversation of another agent may keep serving one: every
  # process on a disk runs as one user, a runtime's credential file stays on
  # the disk after its conversation ends, and the conversation left there
  # would print it into its transcript unredacted.
  #
  # So, for every live machine that has carried a conversation of an agent
  # other than its own (a row on it, or a descriptor the machine kept of one
  # deleted or moved away):
  #
  #   * each live conversation of another agent on it is ended (`terminated`);
  #   * the machine is stamped `destroying`, which every reader refuses at
  #     once (a wake answers `sandbox_reset_pending`, an attach the same), and
  #     the reaper's five-minute teardown run destroys it through its owner,
  #     writing `sandbox.destroyed` and `sandbox.teardown_reconciled`.
  #
  # The machine's own agent's conversations are left as they are. Once the
  # machine is gone, the next prompt of each builds a fresh one, as it would
  # after any destroyed machine; the transcript stays and the runtime session
  # starts again.
  #
  # Guests attach only to a persistent machine with a recorded agent and
  # runtime, and a guest is another agent's conversation, so the scan is
  # limited to exactly that. A home whose own agent changed runtime is not a
  # guest's machine and is left alone.
  #
  # **Another transition is overwritten**, as the destroying backfill
  # (`20260918190000`) does: `Lease.cas_update/4` keeps `destroying` through a
  # live owner's non-terminal write, and a provision's finalize refuses a
  # stamped row. `updated_at` is moved back past the teardown run's 15-minute
  # grace, because no caller is waiting to finish this destroy itself.
  #
  # Rolling deploy: a replica of the previous release could still admit a
  # guest after this commits. An operator who wants to rule that out stops
  # the old replicas first; running this migration again (it is idempotent)
  # also catches one.
  #
  # Nothing is audited here, matching the other data migrations: the destroy
  # is audited by the reaper. The ids are logged.

  @mixed """
  s.status NOT IN ('terminated', 'failed')
  AND s.mode = 'persistent'
  AND s.agent_id IS NOT NULL
  AND (
    EXISTS (
      SELECT 1 FROM conversations c
       WHERE c.sandbox_id = s.id AND c.agent_id IS DISTINCT FROM s.agent_id)
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(s.departed_conversations) AS d
       WHERE (d ->> 'agent_id') IS DISTINCT FROM s.agent_id::text)
  )
  """

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    %{rows: machines} =
      repo().query!("""
      SELECT s.id::text, s.user_id::text, s.provider, s.sprite_name
        FROM sandboxes s
       WHERE #{@mixed}
       ORDER BY s.id
         FOR UPDATE
      """)

    if machines != [] do
      ids = Enum.map(machines, fn [id | _] -> id end)

      %{num_rows: ended} =
        repo().query!(
          """
          UPDATE conversations c
             SET status = 'terminated', updated_at = now()
            FROM sandboxes s
           WHERE s.id = c.sandbox_id
             AND s.id::text = ANY($1::text[])
             AND c.agent_id IS DISTINCT FROM s.agent_id
             AND c.status NOT IN ('terminated', 'failed')
          """,
          [ids]
        )

      repo().query!(
        """
        UPDATE sandboxes
           SET transition = 'destroying',
               transition_reason = 'reclaimed',
               updated_at = now() - interval '1 hour'
         WHERE id::text = ANY($1::text[])
        """,
        [ids]
      )

      for [id, user_id, provider, name] <- machines do
        Logger.warning(
          "migration: mixed-runtime sandbox #{id} (#{provider}/#{name}, user #{user_id}) " <>
            "stamped destroying; the reaper's teardown run destroys it"
        )
      end

      Logger.warning(
        "migration: ended #{ended} guest conversation(s) on #{length(ids)} mixed-runtime " <>
          "sandbox(es)"
      )
    end
  end

  # Nothing to undo: the destroys may already have run, and an ended guest
  # cannot be reattached by the previous release either once its machine is
  # gone.
  def down, do: :ok
end
