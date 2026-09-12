defmodule Fountain.Repo.Migrations.ConversationsNameACredentialSet do
  @moduledoc """
  A launch may run on a credential set other than its agent's (ADR 0053
  decision 3).

  Nullable, and null means "this launch had no opinion", so the agent's set
  answers -- resolved at provision, the same way `conversations.environment_id`
  works, so a conversation whose agent later moves sets follows the agent.

  `on_delete: :nilify_all` for the same reason the agents column has it:
  deleting a credential set must return the conversations that named it to
  the agent's, never delete a transcript.
  """

  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :inference_credential_id,
          references(:inference_credentials, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:conversations, [:inference_credential_id])
  end
end
