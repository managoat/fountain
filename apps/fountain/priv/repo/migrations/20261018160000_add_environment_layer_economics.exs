defmodule Fountain.Repo.Migrations.AddEnvironmentLayerEconomics do
  use Ecto.Migration

  def change do
    create table(:environment_layer_economics, primary_key: false) do
      add :environment_id, references(:environments, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :cohort, :string, null: false
      add :epoch, :uuid, null: false
      add :samples, {:array, :map}, default: [], null: false
      add :mode, :string, default: "learning", null: false
      add :launches, :integer, default: 0, null: false
      add :trial, :uuid
      add :trial_until, :utc_datetime_usec
      add :evaluated_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
