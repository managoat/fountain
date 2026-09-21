defmodule Fountain.InferenceCredentials.Source do
  @moduledoc """
  Non-secret resolved inference identity, persisted on conversations and turns.

  `identity` identifies the owning source and credential kind; `revision`
  distinguishes replacement within that source. Neither contains bearer material.
  A default change affects new selections only. Existing peers must match their
  stored binding before preparing auth or starting another turn.

  `scope` says where the credential came from: the tenant's set
  (`:credential`), a tenant secret named after one (`:tenant_secret`), a
  ChatGPT subscription of the tenant's that their set names (`:grant`, ADR
  0060 decision 2), the deployment (`:platform`), nowhere because the
  provider needs none (`:none`), or nowhere at all (`:missing`). Whether a
  source is the platform's is a function of that, `platform?/1`; the
  `"origin"` key every stored map carries (`"platform"` or `"own"`) is
  written by `dump/1` from the scope and ignored by `load/1`, so rows
  written before it was derived and the `expected_source` comparison keep
  their shape.

  A `:grant` source is the tenant's own, so its origin is `"own"` and it
  never reaches the platform ceiling or the platform debit. It alone carries
  `grant_id` and `generation`, the pin `ChatGPTAccounts.credential_for_user/4`
  takes; its `identity` is `"chatgpt_grant:" <> grant_id` and its `revision`
  the generation, so everything that compares identity and revision already
  tells two grants, and two sign-ins of one grant, apart. The bearer never
  travels with a source.

  `dump/1` writes `"grant_id"` and `"generation"` only when they are set.
  Every stored map is compared whole with a fresh dump, so a key that every
  source started to carry, even as `nil`, would make every conversation
  admitted before it read as `:inference_source_changed`.
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
    :vault_id,
    :grant_id,
    :generation
  ]

  # Absent from a stored map unless set. See the moduledoc.
  @optional ~w(grant_id generation)

  def credential, do: %__MODULE__{scope: :credential}
  def tenant_secret, do: %__MODULE__{scope: :tenant_secret}
  def grant, do: %__MODULE__{scope: :grant}
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
    |> Map.reject(fn {key, value} -> key in @optional and is_nil(value) end)
    |> Map.put("origin", origin(source))
  end

  @doc """
  What a stored source says to its owner, for a turn's `inference` field in
  the API and the export (ADR 0060 decision 6): the `"origin"`, the scope and,
  on a `:grant` source, which subscription. Nil for a row with no source, or
  with one whose scope this version does not know.

  Deliberately three keys. `generation`, `identity` and `revision` are
  fencing values and are in no body; the set, the environment and the vault
  are on the conversation.
  """
  @spec summary(map() | nil) ::
          %{origin: String.t(), scope: String.t(), chatgpt_grant_id: String.t() | nil} | nil
  def summary(nil), do: nil

  def summary(%{} = stored) do
    case load(stored) do
      %__MODULE__{scope: nil} ->
        nil

      %__MODULE__{scope: scope} = source ->
        %{
          origin: origin(source),
          scope: Atom.to_string(scope),
          chatgpt_grant_id: if(scope == :grant, do: source.grant_id)
        }
    end
  end

  def load(nil), do: nil

  def load(%{} = source) do
    %__MODULE__{
      scope:
        decode(source["scope"], [:credential, :tenant_secret, :grant, :platform, :none, :missing]),
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
      vault_id: source["vault_id"],
      grant_id: source["grant_id"],
      generation: source["generation"]
    }
  end

  @doc """
  The managed ChatGPT grant a source is pinned to: whose it is, its id and
  the generation it was resolved at, or `nil` for a source that is not on a
  grant. Never a token. The platform's is read out of its identity and
  revision, which is where that path has always kept them.
  """
  @spec grant_ref(t() | nil) :: {:user | :platform, String.t(), String.t()} | nil
  def grant_ref(%__MODULE__{scope: :grant, grant_id: id, generation: generation})
      when is_binary(id) and is_binary(generation),
      do: {:user, id, generation}

  def grant_ref(%__MODULE__{
        scope: :platform,
        kind: :codex_chatgpt_access_token,
        identity: "platform:chatgpt:" <> id,
        revision: generation
      })
      when is_binary(generation),
      do: {:platform, id, generation}

  def grant_ref(_), do: nil

  defp decode(value, allowed), do: Enum.find(allowed, &(Atom.to_string(&1) == value))
end
