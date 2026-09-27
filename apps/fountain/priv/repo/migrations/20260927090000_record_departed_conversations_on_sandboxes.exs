defmodule Fountain.Repo.Migrations.RecordDepartedConversationsOnSandboxes do
  use Ecto.Migration

  # #2515 (ADR 0023, 2026-09-26 amendment). A machine that has carried a
  # conversation of another runtime keeps that runtime's files — codex's
  # `~/.codex/auth.json` among them — until it is destroyed or reset. Two
  # readers answer "who has been on this disk" from the conversation rows,
  # retired ones included: the attach rule
  # (`Fountain.Machines.Binding.attachable/5`) and the co-tenant redaction
  # registry (`Fountain.Conversations.CotenantSecrets`). Deleting a
  # conversation removes its row while the machine it ran on is kept, and with
  # it the machine's only memory of that runtime.
  #
  # A conversation row repointed at another machine leaves the same way: a
  # guest whose environment or vault moved off its home is sent to a machine
  # of its own (`Fountain.Conversations.Wake`), and its files stay on the home
  # it left. The other repoint, a wake moving co-tenants off a dead machine,
  # runs after that machine is terminal and records nothing.
  #
  # So a conversation row that is deleted, or repointed, while its machine is
  # live leaves a descriptor on the machine: what re-resolving its inference credential
  # needs, and nothing secret — its runtime, agent, model, stored inference
  # source (a revision reference, never a value), credential set, and the
  # environment and vault it ran against. Readers union these with the rows.
  # One descriptor per distinct source, not per conversation, so a busy home
  # does not grow a row per deletion.
  #
  # **A trigger, not the application.** A row is deleted from more than one
  # place (`Conversations.delete_conversation/2`, an attach whose first prompt
  # was refused) and repointed from more than one, and a descriptor a new path
  # forgets is the disclosure. An AFTER trigger sees every one of them. A machine already terminal, or
  # deleted in the same statement (a cascade from the sandbox or the user),
  # matches no row and records nothing: that disk is gone.
  #
  # The environment is the one the conversation ran against: its own, or the
  # machine's, which every conversation on a machine matches when it attaches.
  #
  # `sandboxes` is written by every provision, wake and reaper pass; adding a
  # column with a constant default is a catalog change, but the ACCESS
  # EXCLUSIVE lock still queues behind a long reader, so give up after five
  # seconds rather than hold the queue.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:sandboxes) do
      add :departed_conversations, :map, null: false, default: fragment("'[]'::jsonb")
    end

    execute("""
    CREATE FUNCTION fountain_record_departed_conversation() RETURNS trigger AS $$
    DECLARE descriptor jsonb;
    BEGIN
      IF OLD.sandbox_id IS NULL THEN RETURN NULL; END IF;
      IF TG_OP = 'UPDATE' AND OLD.sandbox_id IS NOT DISTINCT FROM NEW.sandbox_id THEN
        RETURN NULL;
      END IF;

      SELECT jsonb_build_object(
               'conversation_id', OLD.id,
               'agent_id', OLD.agent_id,
               'runtime', OLD.runtime,
               'model', OLD.model,
               'inference_source', OLD.inference_source,
               'inference_credential_id', OLD.inference_credential_id,
               'environment_id', COALESCE(OLD.environment_id, s.environment_id),
               'vault_id', OLD.vault_id)
        INTO descriptor
        FROM sandboxes AS s
       WHERE s.id = OLD.sandbox_id;

      IF descriptor IS NULL THEN RETURN NULL; END IF;

      UPDATE sandboxes AS s
         SET departed_conversations = s.departed_conversations || jsonb_build_array(descriptor)
       WHERE s.id = OLD.sandbox_id
         AND s.status NOT IN ('terminated', 'failed')
         AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(s.departed_conversations) AS e
            WHERE (e - 'conversation_id') = (descriptor - 'conversation_id'));

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER record_departed_conversation
    AFTER DELETE OR UPDATE OF sandbox_id ON conversations
    FOR EACH ROW EXECUTE FUNCTION fountain_record_departed_conversation()
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP TRIGGER record_departed_conversation ON conversations")
    execute("DROP FUNCTION fountain_record_departed_conversation()")

    alter table(:sandboxes) do
      remove :departed_conversations
    end
  end
end
