defmodule Fountain.Repo.Migrations.OneConversationPerSandbox do
  use Ecto.Migration

  require Logger

  # Persistent homes are removed (#2676): every sandbox is one conversation's,
  # destroyed when that conversation ends. This release no longer reads
  # `sandboxes.mode`, attaches by `sandbox_id`, or keeps a machine for its
  # other conversations, so a live machine that still carries several live
  # conversations has to come down to one before it serves anything. Otherwise
  # the first of them to end would destroy the disk under the others.
  #
  # For every live sandbox with more than one live conversation (homes, and
  # ephemeral machines that took a child by `sandbox_id`), one conversation
  # keeps the machine:
  #
  #   1. the Team conversation on it (`channel_id = 'fountain:team'`), since a
  #      teammate is the long-lived thread a home most often served;
  #   2. otherwise the conversation with the most recent turn, falling back to
  #      the newest conversation for one that never took a turn.
  #
  # Every other live conversation on it is **detached**, not ended: it is
  # repointed at a new `terminated` sandbox row of its own (same user, agent,
  # environment, vault, provider and machine name, so the row still describes
  # where it ran) and its `runtime_session_id` is cleared. Its transcript is
  # kept, and its next prompt finds a terminated machine, which the wake reads
  # as `:create_new`, and provisions a fresh one. The name is reused safely:
  # `sandboxes_live_machine_name_index` covers live rows only. The new rows
  # are born terminated, so they hold no fleet slot and meter no time.
  #
  # Repointing fires `record_departed_conversation`, which appends a
  # descriptor to the kept machine's `departed_conversations`. Nothing reads
  # that column any more; the drop release removes it and the trigger.
  #
  # Conversations already `terminated` or `failed` keep pointing at the
  # machine they ran on, as history.
  #
  # Rolling deploy: a replica of the previous release could still attach a
  # conversation to a home after this commits. Stopping the old replicas
  # first rules that out, and running this migration again (it is idempotent)
  # catches one. A conversation mid-turn on an old replica when this runs is
  # detached under its server; run it while nothing is mid-turn.
  #
  # Nothing is audited, matching the other data migrations. The detached ids
  # are logged.

  @live_statuses_sql "('terminated', 'failed')"

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    %{rows: detached} =
      repo().query!("""
      WITH ranked AS (
        SELECT c.id,
               c.sandbox_id,
               row_number() OVER (
                 PARTITION BY c.sandbox_id
                 ORDER BY (c.channel_id = 'fountain:team') IS TRUE DESC,
                          COALESCE(
                            (SELECT max(t.inserted_at) FROM turns t WHERE t.conversation_id = c.id),
                            c.inserted_at
                          ) DESC,
                          c.inserted_at DESC,
                          c.id DESC
               ) AS rank
          FROM conversations c
          JOIN sandboxes s ON s.id = c.sandbox_id
         WHERE s.status NOT IN #{@live_statuses_sql}
           AND c.status NOT IN #{@live_statuses_sql}
      )
      SELECT r.id::text, r.sandbox_id::text
        FROM ranked r
       WHERE r.rank > 1
       ORDER BY r.sandbox_id, r.id
      """)

    for [conv_id, sandbox_id] <- detached do
      repo().query!(
        """
        WITH placeholder AS (
          INSERT INTO sandboxes
            (id, user_id, agent_id, environment_id, vault_id, sprite_name, provider,
             provider_meta, status, mode, terminated_at, inserted_at, updated_at)
          SELECT gen_random_uuid(), s.user_id, s.agent_id, s.environment_id, s.vault_id,
                 s.sprite_name, s.provider, '{}'::jsonb, 'terminated', 'ephemeral',
                 date_trunc('second', timezone('UTC', now())),
                 date_trunc('second', timezone('UTC', now())),
                 date_trunc('second', timezone('UTC', now()))
            FROM sandboxes s
           WHERE s.id::text = $2
          RETURNING id
        )
        UPDATE conversations
           SET sandbox_id = (SELECT id FROM placeholder),
               runtime_session_id = NULL,
               updated_at = date_trunc('second', timezone('UTC', now()))
         WHERE id::text = $1
        """,
        [conv_id, sandbox_id]
      )
    end

    if detached != [] do
      machines = detached |> Enum.map(&List.last/1) |> Enum.uniq() |> length()

      Logger.warning(
        "migration: detached #{length(detached)} conversation(s) from #{machines} shared " <>
          "sandbox(es); each provisions a fresh sandbox on its next prompt: " <>
          Enum.map_join(detached, ", ", &List.first/1)
      )
    end
  end

  # Nothing to undo: the previous release can wake a detached conversation on
  # a fresh machine just as this one does.
  def down, do: :ok
end
