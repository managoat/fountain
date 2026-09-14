defmodule Fountain.InferenceCredentials.Source do
  @moduledoc """
  Non-secret resolved inference identity, persisted on conversations and turns.

  `identity` identifies the owning source and credential kind; `revision`
  distinguishes replacement within that source. Neither contains bearer material.
  A default change affects new selections only. Existing peers must match their
  stored binding before preparing auth or starting another turn.

  `scope` says where the credential came from: the tenant's set
  (`:credential`), a tenant secret named after one (`:tenant_secret`), the
  deployment (`:platform`), nowhere because the provider needs none
  (`:none`), or nowhere at all (`:missing`). Whether a source is the
  platform's is a function of that, `platform?/1`; the `"origin"` key every
  stored map carries (`"platform"` or `"own"`) is written by `dump/1` from
  the scope and ignored by `load/1`, so rows written before it was derived
  and the `expected_source` comparison keep their shape.
  """
  @type t :: %__MODULE__{}
  @enforce_keys [:scope]
  defstruct [
    :scope,
    :kind,
    :identity,
    :revision,
    :set_id,
    :runtime,
    :model,
    :environment_id,
    :vault_id
  ]

  def credential, do: %__MODULE__{scope: :credential}
  def tenant_secret, do: %__MODULE__{scope: :tenant_secret}
  def none, do: %__MODULE__{scope: :none}
  def platform, do: %__MODULE__{scope: :platform}
  def missing, do: %__MODULE__{scope: :missing}
  def platform?(%__MODULE__{scope: :platform}), do: true
  def platform?(_), do: false

  @doc """
  The `"origin"` a stored map carries: `"platform"` for a platform source,
  else `"own"`.
  """
  @spec origin(t()) :: String.t()
  def origin(%__MODULE__{} = source), do: if(platform?(source), do: "platform", else: "own")

  def dump(nil), do: nil

  def dump(%__MODULE__{} = source) do
    source
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key),
       if(is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value)}
    end)
    |> Map.put("origin", origin(source))
  end

  def load(nil), do: nil

  def load(%{} = source) do
    %__MODULE__{
      scope: decode(source["scope"], [:credential, :tenant_secret, :platform, :none, :missing]),
      kind:
        decode(source["kind"], [
          :anthropic_api_key,
          :claude_code_oauth_token,
          :openai_api_key,
          :gemini_api_key,
          :codex_chatgpt_access_token
        ]),
      identity: source["identity"],
      revision: source["revision"],
      set_id: source["set_id"],
      runtime: source["runtime"],
      model: source["model"],
      environment_id: source["environment_id"],
      vault_id: source["vault_id"]
    }
  end

  defp decode(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
end
