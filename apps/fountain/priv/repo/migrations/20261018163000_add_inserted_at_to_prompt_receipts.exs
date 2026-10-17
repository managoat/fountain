defmodule Fountain.Repo.Migrations.AddInsertedAtToPromptReceipts do
  use Ecto.Migration

  # Nullable on purpose: a receipt written before this column existed has no
  # age, and boot recovery treats an ageless receipt as expired rather than
  # reporting a prompt that may have been lost long ago (ADR 0089).
  def change do
    alter table(:prompt_receipts) do
      add :inserted_at, :utc_datetime_usec
    end
  end
end
