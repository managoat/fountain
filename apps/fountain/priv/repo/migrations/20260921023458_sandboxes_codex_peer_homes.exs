defmodule Fountain.Repo.Migrations.SandboxesCodexPeerHomes do
  use Ecto.Migration

  # ADR 0053 decision 6's "interim machine-lifetime source binding", relaxed
  # by ADR 0060 stage 3 where isolation is provable and nowhere else.
  #
  # A codex machine is bound to one inference source for its life
  # (`codex_inference_source`), because every codex peer on it shared one
  # `~/.codex/auth.json`. A managed ChatGPT grant now keeps its account file in
  # a `CODEX_HOME` of its own (`Fountain.Conversations.CodexChatGPT`), so two
  # such peers do not collide, and the binding need not refuse them.
  #
  # `codex_peer_homes` says the machine was first bound under that code: no
  # codex process on it has ever been started on a managed grant's file in the
  # shared directory. It is set at a machine's first Codex bind and never
  # afterwards, so every existing row is `false` and keeps today's rule, the
  # deployment's grant included.
  #
  # A constant default, so no rewrite, but the lock is ACCESS EXCLUSIVE and
  # `sandboxes` is written by every provision, wake and reaper pass: give up
  # after five seconds rather than queue all of them behind a long reader.
  def change do
    execute("SET LOCAL lock_timeout = '5s'", "SET LOCAL lock_timeout = '5s'")

    alter table(:sandboxes) do
      add :codex_peer_homes, :boolean, null: false, default: false
    end
  end
end
