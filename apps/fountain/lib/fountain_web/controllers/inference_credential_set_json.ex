defmodule FountainWeb.InferenceCredentialSetJSON do
  @moduledoc false

  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Credential

  def index(%{sets: sets}), do: %{data: Enum.map(sets, &data/1)}
  def show(%{set: set}), do: %{data: data(set)}

  def data(%Credential{} = set) do
    %{
      id: set.id,
      name: set.name,
      is_default: set.is_default,
      providers: providers(set),
      inserted_at: set.inserted_at,
      updated_at: set.updated_at
    }
  end

  # Which credentials this set holds, by name. Derived from the same status
  # map the per-provider surface renders, so the two cannot disagree about
  # what "set" means, and never the values: this whole resource is
  # write-only in that direction.
  defp providers(set) do
    set
    |> InferenceCredentials.status_for_set()
    |> Enum.filter(fn {_provider, held?} -> held? end)
    |> Enum.map(fn {provider, _} -> Atom.to_string(provider) end)
    |> Enum.sort()
  end
end
