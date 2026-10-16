defmodule Fountain.EnvironmentLayers.EconomicsState do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:environment_id, :binary_id, autogenerate: false}
  schema "environment_layer_economics" do
    field :user_id, Ecto.UUID
    field :cohort, :string
    field :epoch, Ecto.UUID
    field :samples, {:array, :map}, default: []
    field :mode, :string, default: "learning"
    field :launches, :integer, default: 0
    field :trial, Ecto.UUID
    field :trial_until, :utc_datetime_usec
    field :evaluated_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
