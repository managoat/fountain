defmodule Fountain.Repo.Migrations.ClearChatgptGrantPointers do
  use Ecto.Migration

  # ChatGPT subscriptions are removed (ADR 0060, retired 2026-10-13). Nothing
  # reads `inference_credentials.chatgpt_grant_id` any more, so a set that
  # named a subscription is cleared here: its codex runs now resolve like any
  # other set's, on its OpenAI key or not at all. A conversation that ran on
  # the subscription stays pinned to that source and is refused with
  # `inference_source_changed` at its next turn.
  #
  # The column, its deferred foreign key and the grant tables stay one release,
  # so a replica of the previous release keeps working during the rollout; a
  # later migration drops them. Clearing a reference never violates the key.
  # `revision` does not move: its trigger looks only at the four ciphertexts.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute(
      "UPDATE inference_credentials SET chatgpt_grant_id = NULL WHERE chatgpt_grant_id IS NOT NULL"
    )
  end

  # Which subscription each set named is not kept anywhere, so there is
  # nothing to restore.
  def down, do: :ok
end
