defmodule Fountain.Repo.Migrations.AddApiKeysConversationBinding do
  @moduledoc """
  Adds `api_keys.conversation_id` and `api_keys.parent_key_id` (#2934, ADR
  0086): the `conversation`-scoped key an `"auth": "conversation"` MCP server
  receives names the one conversation it may read, and the sandbox callback
  key it was minted from. Revoking that callback key revokes it too
  (`Accounts.revoke_api_key/3`), and a deleted parent or conversation deletes
  it.

  Nullable and empty on every existing row, with partial indexes for the
  lookup by parent. `down` drops both columns; a `conversation` key left
  behind then keeps its scope but loses its binding, and the scope plug
  refuses every request it makes.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:api_keys) do
      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: true

      add :parent_key_id,
          references(:api_keys, type: :binary_id, on_delete: :delete_all),
          null: true
    end

    create index(:api_keys, [:parent_key_id], where: "parent_key_id IS NOT NULL")
    create index(:api_keys, [:conversation_id], where: "conversation_id IS NOT NULL")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:api_keys) do
      remove :parent_key_id
      remove :conversation_id
    end
  end
end
