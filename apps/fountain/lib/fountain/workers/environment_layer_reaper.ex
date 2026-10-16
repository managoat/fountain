defmodule Fountain.Workers.EnvironmentLayerReaper do
  @moduledoc "Cancel obsolete/abandoned builders and retry machine/object cleanup (ADR 0090)."
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 55]

  @impl Oban.Worker
  def perform(_job), do: Fountain.EnvironmentLayers.Builds.reap()
end
