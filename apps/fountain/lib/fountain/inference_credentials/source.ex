defmodule Fountain.InferenceCredentials.Source do
  @moduledoc """
  Non-secret resolved inference identity, persisted on conversations and turns.

  `identity` identifies the owning source and credential kind; `revision`
  distinguishes replacement within that source. Neither contains bearer material.
  Existing peers must match their stored binding before preparing auth or
  starting another turn. `set_id` is the id of the user's credential record
  the source was read from, or nil; it keeps the name it had when an account
  could hold several named sets (retired 2026-10-14), because a stored map
  with a different key would no longer equal a fresh dump.

  `scope` says where the credential came from: the tenant's credential
  record (`:credential`), a tenant secret named after one (`:tenant_secret`), the
  tenant's ChatGPT subscription (`:grant`, ADR 0070), nowhere because the
  provider needs none (`:none`), or nowhere at all (`:missing`).

  Every stored map carries `"origin" => "own"`, which `load/1` ignores. It
  once told the tenant's credentials from the deployment's, which were
  removed (ADR 0075). It stays in `dump/1` because a stored map is compared
  whole with a fresh dump: dropping it would end every conversation admitted
  before. A stored source of scope `"platform"` loads with a nil scope, and
  no fresh dump equals it, so a conversation bound to the deployment's
  credential is refused with `:inference_source_changed` at its next turn.

  A ChatGPT subscription's source is kind `:codex_chatgpt_access_token`,
  identity `"chatgpt:<user id>"` (scope `:grant`), and revision the
  subscription's account id: a token refresh keeps the source, a link to
  another account changes it. `chatgpt_owner/1` reads the user back from the
  identity.

  Rows written by the retired implementation (ADR 0060, before 2026-10-13)
  carry `"grant_id"` and `"generation"` as well. They load and render as a
  subscription, but no fresh dump equals them, so a conversation pinned to
  one fails its next turn with `:inference_source_changed`. Every stored map is compared whole with a fresh dump, so a key that every
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
    :vault_id
  ]

  @scopes [:credential, :tenant_secret, :grant, :none, :missing]

  @doc "Every scope a source can have; the API's `inference.scope` enum is this list."
  @spec scopes() :: [atom()]
  def scopes, do: @scopes

  def credential, do: %__MODULE__{scope: :credential}
  def tenant_secret, do: %__MODULE__{scope: :tenant_secret}
  def grant, do: %__MODULE__{scope: :grant}
  def none, do: %__MODULE__{scope: :none}
  def missing, do: %__MODULE__{scope: :missing}

  def dump(nil), do: nil

  def dump(%__MODULE__{} = source) do
    source
    |> Map.from_struct()
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key),
       if(is_atom(value) and not is_nil(value), do: Atom.to_string(value), else: value)}
    end)
    |> Map.put("origin", "own")
  end

  @doc """
  What a stored source says to its owner, for a turn's `inference` field in
  the API (ADR 0060 decision 6): the scope. Nil for a row with no source, or
  with one whose scope this version does not know (`"platform"`, from before
  ADR 0075, among them).

  Deliberately one key. `generation`, `identity` and `revision` are
  fencing values and are in no body; the environment and the vault
  are on the conversation.
  """
  @spec summary(map() | nil) :: %{scope: String.t()} | nil
  def summary(nil), do: nil

  def summary(%{} = stored) do
    case load(stored) do
      %__MODULE__{scope: nil} ->
        nil

      %__MODULE__{scope: scope} ->
        %{scope: Atom.to_string(scope)}
    end
  end

  def load(nil), do: nil

  def load(%{} = source) do
    %__MODULE__{
      scope: decode(source["scope"], @scopes),
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

  @doc """
  The ChatGPT subscription a source runs on, as its user's id, and the
  account it was bound to; nil for every other source, for a source the
  retired implementation wrote, and for one on the deployment's subscription
  (`"platform:chatgpt"`, removed by ADR 0075).
  """
  @spec chatgpt_owner(t() | map() | nil) :: {Ecto.UUID.t(), String.t()} | nil
  def chatgpt_owner(%__MODULE__{kind: :codex_chatgpt_access_token} = source),
    do: owner_of(source.identity, source.revision)

  def chatgpt_owner(%{"kind" => "codex_chatgpt_access_token"} = stored),
    do: owner_of(stored["identity"], stored["revision"])

  def chatgpt_owner(_), do: nil

  defp owner_of("chatgpt:" <> user_id, account) when is_binary(account) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> {id, account}
      :error -> nil
    end
  end

  defp owner_of(_, _), do: nil
end
