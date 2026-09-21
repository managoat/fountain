defmodule FountainWeb.InferenceCredentialSetJSON do
  @moduledoc false

  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Credential

  # `grants` is the owner's grants by id, read once by the controller and
  # scoped by the owner there; a set's own `chatgpt_grant_id` is looked up in
  # it, so a list of sets costs one grant read and not one per set.
  def index(%{sets: sets, grants: grants}), do: %{data: Enum.map(sets, &data(&1, grants))}
  def show(%{set: set, grants: grants}), do: %{data: data(set, grants)}

  def data(%Credential{} = set, grants) when is_map(grants) do
    %{
      id: set.id,
      name: set.name,
      is_default: set.is_default,
      providers: providers(set),
      chatgpt_grant_id: set.chatgpt_grant_id,
      chatgpt_grant: named_grant(set, grants),
      inserted_at: set.inserted_at,
      updated_at: set.updated_at
    }
  end

  # The ChatGPT subscription the set names, as much of it as says whether the
  # set's codex runs will work: a reference, never a credential. The whole
  # subscription is at `/api/account/chatgpt-subscriptions`.
  defp named_grant(%Credential{chatgpt_grant_id: nil}, _grants), do: nil

  defp named_grant(%Credential{chatgpt_grant_id: id}, grants) do
    case Map.get(grants, id) do
      %{name: name, status: status} -> %{id: id, name: name, status: status}
      nil -> nil
    end
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
