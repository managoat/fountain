defmodule Fountain.Repo.Migrations.AgentsNameACredentialSet do
  @moduledoc """
  An agent may name the credential set its conversations run on, and bound
  which set a launch may name instead (ADR 0053 decision 3).

  Both nullable, and null means what it meant before either column existed:
  the account's default set, and any set the tenant owns. `on_delete:
  :nilify_all` rather than `:delete_all` -- deleting a credential set must not
  delete the agents that named it, it must return them to the default, which
  is the same thing `agents.environment_id` does.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :inference_credential_id,
          references(:inference_credentials, type: :binary_id, on_delete: :nilify_all)

      add :allowed_inference_credential_ids, {:array, :binary_id}
    end

    create index(:agents, [:inference_credential_id])
  end
end
