defmodule Fountain.Repo.Migrations.DropTeamComms do
  @moduledoc """
  Team comms — a teammate's AgentMail inbox and AgentPhone number, and the
  message log the ledger used to price — is removed. Nothing reads either
  table any more; the rows were never more than a proof of concept.
  """
  use Ecto.Migration

  def up do
    drop table(:comms_messages)
    drop table(:team_contacts)
  end

  # The shape the tables had when they went, so a rollback restores a
  # schema the previous release can run against. The rows are gone.
  def down do
    create table(:team_contacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :email_address, :string
      add :email_inbox_id, :string
      add :phone_number, :string
      add :phone_number_id, :string
      add :phone_agent_id, :string
      add :prompt_from_number, :string
      add :prompt_opted_out_at, :utc_datetime
      add :rent_paid_through, :utc_datetime
      add :rent_due_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_contacts, [:user_id, :agent_id])
    create index(:team_contacts, [:agent_id])
    create index(:team_contacts, [:phone_number])
    create index(:team_contacts, [:rent_paid_through])

    create table(:comms_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :contact_id, references(:team_contacts, type: :binary_id, on_delete: :nilify_all)
      add :agent_id, :binary_id
      add :channel, :string, null: false
      add :direction, :string, null: false
      add :provider_message_id, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:comms_messages, [:user_id, :channel, :provider_message_id],
             name: :comms_messages_provider_id_index
           )

    create index(:comms_messages, [:inserted_at])
    create index(:comms_messages, [:user_id, :inserted_at])
  end
end
