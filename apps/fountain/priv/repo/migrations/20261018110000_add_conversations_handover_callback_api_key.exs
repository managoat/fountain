defmodule Fountain.Repo.Migrations.AddConversationsHandoverCallbackApiKey do
  @moduledoc """
  Adds `conversations.handover_callback_api_key_id` (#2835, ADR 0086): the
  callback key a server that stopped gracefully mid-turn left to the server
  that reattaches the turn. The running adapter still holds that key in its
  `MANAGOAT_TOKEN` and in its `"auth": "conversation"` MCP headers, so it
  stays valid, and names the conversation, until the turn ends; the
  reattaching server then revokes it and clears the column.

  Nullable and empty on every existing row, with a partial index for the
  lookup by key (`Conversations.get_conversation_for_callback_key/2`).
  `down` drops it; a key left in it then lives until its `expires_at`.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      add :handover_callback_api_key_id,
          references(:api_keys, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    create index(:conversations, [:handover_callback_api_key_id],
             where: "handover_callback_api_key_id IS NOT NULL"
           )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      remove :handover_callback_api_key_id
    end
  end
end
