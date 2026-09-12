defmodule Fountain.InferenceCredentials.Source do
  @moduledoc """
  Which credential served a conversation, and where it came from (ADR 0053
  decision 2).

  `Fountain.InferenceCredentials.select/4` returns one of these instead of a
  bare `:own | :platform`. The conversation holds it for its lifetime and the
  turn's usage stamp is derived from it, so the answer to "whose key paid for
  this turn" is decided once and read everywhere.

  Two fields, because two fields have readers:

    * `origin` — the billing question, in the vocabulary the ledger already
      uses. `:platform` prices the turn against the tenant's credits and
      counts it against the deployment's daily ceiling; `:own` does neither.
    * `scope` — where the value came from. `:credential` an
      `inference_credentials` row, `:platform` a platform key or the
      deployment's ChatGPT grant, `:none` a provider that needs no credential
      at all (a local model, a gateway), `:missing` a provider that needs one
      where neither the tenant nor the deployment has it.

  `:none` and `:missing` are both `origin: :own` and are both what `main`
  called `:own` before this struct existed, so nothing about billing moves.
  They are separate because they are opposite answers to "is anything wrong
  here": a local model needs no key, and a conversation with no key for a
  provider that requires one will fail inside the sandbox. Keeping them apart
  is what lets a surface say which without asking the question again.

  `origin` and `scope` are not the same question. ADR 0053 decision 5 adds
  `:tenant_secret`, an environment or vault secret naming a credential, which
  is `origin: :own` and needs to stay distinguishable from a credential row
  for anything that reports where a turn ran.

  **There is deliberately no `kind`.** A field naming the credential atom that
  served the turn would have to guess how the runtime chose between an
  account's credentials, and the runtimes disagree: `Managoat.Runtimes.Claude`
  prefers `CLAUDE_CODE_OAUTH_TOKEN` and never exports the API key beside it,
  while `Managoat.Runtimes.OpenCode` reads only the API key for the same
  provider. Any derivation here would state the wrong credential for an
  account holding both. It belongs to whichever change first needs to bill or
  report per credential, with a derivation that matches the runtime. ADR 0052
  decision 4 adds `grant_id` and `generation` to this struct for the same
  reason: a field arrives with its reader.
  """

  @type origin :: :own | :platform
  @type scope :: :credential | :platform | :none | :missing

  @type t :: %__MODULE__{origin: origin(), scope: scope()}

  @enforce_keys [:origin, :scope]
  defstruct [:origin, :scope]

  @doc "The tenant's own credential row served this conversation."
  @spec credential() :: t()
  def credential, do: %__MODULE__{origin: :own, scope: :credential}

  @doc """
  The model's provider needs no credential — a local model, a gateway, or a
  provider Fountain does not know. Nothing is missing and nothing is
  platform-paid.
  """
  @spec none() :: t()
  def none, do: %__MODULE__{origin: :own, scope: :none}

  @doc "This deployment's platform key, or its ChatGPT grant, served it."
  @spec platform() :: t()
  def platform, do: %__MODULE__{origin: :platform, scope: :platform}

  @doc """
  The model's provider needs a credential and nobody has one.

  The conversation still provisions — that predates platform keys and is
  deliberate, because the provider's own auth error on the transcript says
  more than a refusal invented here. `origin: :own` because the deployment is
  not paying for a turn nothing served.
  """
  @spec missing() :: t()
  def missing, do: %__MODULE__{origin: :own, scope: :missing}

  @doc """
  Whether the deployment pays for this conversation's inference.

  The one question the ledger and the daily ceiling ask. Written here so a
  call site reads what it means rather than comparing an atom.
  """
  @spec platform?(t() | nil) :: boolean()
  def platform?(%__MODULE__{origin: :platform}), do: true
  def platform?(_), do: false
end
