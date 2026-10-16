defmodule Fountain.Repo.Migrations.CreatePromptReceipts do
  use Ecto.Migration

  def change do
    create table(:prompt_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :boot_id, :text, null: false
      add :client_request_id, :text
    end

    create index(:prompt_receipts, [:conversation_id])
  end
end
