defmodule FountainWeb.ApplyJSON do
  @moduledoc false

  def create(%{results: results}) do
    %{data: %{results: Enum.map(results, &result_json/1)}}
  end

  defp result_json(result) do
    %{
      kind: result.kind,
      name: result.name,
      action: result.action,
      errors: result.errors,
      secrets: Enum.map(result.secrets, &Map.take(&1, [:key, :action, :errors]))
    }
  end
end
