defmodule Fountain.Workers.EnvironmentLayerBuild do
  @moduledoc "Run one claimed build; retries never reuse a partially built filesystem."
  use Oban.Worker,
    queue: :environment_builds,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "build_id" => build_id}}) do
    case Fountain.EnvironmentLayers.Pipeline.run(user_id, build_id) do
      {:ok, _} -> :ok
      {:error, _} -> {:cancel, "environment build unavailable"}
    end
  end
end
