defmodule Fountain.Conversations.SpriteEnv do
  @moduledoc """
  The sandbox's environment: rows and decrypted secrets in, an ordered
  `{name, value}` list out.

  One precedence rule, stated here and nowhere else: **a vault wins over an
  environment on key collision** (`merge_secrets/3`). In the assembled list
  (`build/4`) the runtime's own defaults come first and the broker's proxy
  variables last, and the list is registered with
  `Fountain.Conversations.Redaction` before it is returned, so what the
  agent sees is exactly what is scrubbed from its output.

  Functions over rows and values, not over server state (#1369). Nothing
  here talks to a sandbox; the writes that carry the list into one are
  `Fountain.Conversations.Provisioning`'s.
  """

  alias Fountain.{Crypto, Environments, InferenceCredentials, Vaults}
  alias Fountain.Conversations.CallbackKey
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  # Load the per-tenant DEK and decrypted inference credentials. Both are
  # held in GenServer state for the conversation lifetime; the DEK is used
  # for ad-hoc decryption (vaults, environments) and the credentials map
  # is passed to runtime modules via build_sprite_env.
  @doc """
  The credential set pinned in a conversation's source binding.

  For a new selection, the launch override wins over the agent's set, then
  the account default. Admission persists the resolved source; wake and
  resume retain that binding even after the agent or account default changes.
  A stored nil set ID means that selection had no credential set and stays nil.
  """
  @spec credential_set_id(map(), map() | nil) :: binary() | nil
  def credential_set_id(conv, agent) do
    case Map.get(conv, :inference_source) do
      %{} = source -> source["set_id"]
      _ -> Map.get(conv, :inference_credential_id) || (agent && agent.inference_credential_id)
    end
  end

  def resolve_inference(conv, agent, env, vault) do
    Fountain.Conversations.InferenceBinding.with_current(conv, fn conv ->
      with {:ok, dek} <- Crypto.load_tenant_key(conv.user_id),
           {:ok, source, creds} <-
             InferenceCredentials.resolve(conv.user_id, agent && agent.model, conv.runtime,
               credential_set_id: credential_set_id(conv, agent),
               environment_id: env && env.id,
               vault_id: vault && vault.id,
               expected_source: Map.get(conv, :inference_source)
             ),
           :ok <- Fountain.Conversations.InferenceBinding.reserve(conv, source) do
        {:ok, dek, source, creds}
      end
    end)
  end

  # Explicit IDs are tenant-scoped and must exist. Only nil asks for the
  # account default; a missing or foreign named set never falls back to it.
  @spec load_tenant_state(String.t(), binary() | nil) :: {:ok, binary(), map()} | {:error, term()}
  def load_tenant_state(user_id, set_id \\ nil) when is_binary(user_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, creds} <- InferenceCredentials.decrypted_for(user_id, set_id, dek) do
      {:ok, dek, creds}
    end
  end

  @doc """
  Resolve a source and its runtime credential inputs from already-loaded values.

  `runtime` falls back to the agent's runtime. `secrets` supplies actual
  environment/vault values, normalized by the shared resolver. Same-kind
  overrides win over credential rows, then runtime kind precedence selects
  the auth input. Competing inputs are removed from the returned credentials.

  This value-only helper returns a `:missing` source when nothing is found;
  production admission and provisioning use `resolve_inference/4` to persist
  and validate the source identity and revision. Invalid supplied credentials
  return an actionable error rather than selecting platform inference.
  """
  @spec select_inference(map() | nil, map(), String.t() | nil, map()) ::
          {InferenceCredentials.Source.t(), map()} | {:error, term()}
  def select_inference(agent, own_creds, runtime \\ nil, secrets \\ %{}) do
    brokered? = Fountain.Broker.configured?()
    runtime = runtime || (agent && agent.runtime)

    case InferenceCredentials.select(agent && agent.model, own_creds, runtime,
           brokered: brokered?,
           overrides: secrets
         ) do
      {:ok, source, creds} -> {source, creds}
      {:error, reason} -> {:error, reason}
    end
  end

  # Env secrets first, vault overrides last — vault wins on key collision.
  # Same merged map feeds repositories[].secret_key resolution.
  @spec merge_secrets(Environment.t() | nil, Vault.t() | nil, binary()) :: %{
          String.t() => String.t()
        }
  def merge_secrets(env, vault, dek) do
    env_secrets = if env, do: Environments.decrypted_env(env, dek), else: %{}
    vault_secrets = if vault, do: Vaults.decrypted_env(vault, dek), else: %{}
    Map.merge(env_secrets, vault_secrets)
  end

  @doc """
  The sandbox's environment, assembled in the order the pieces have always
  come in: the runtime's own defaults, the callback pair, the conversation
  and sandbox ids, the sandbox URL, the trace context, the git author, the
  broker's CA defaults, the environment's plain variables, the decrypted
  secrets and, last, the broker's proxy variables.

  The broker's pairs sit on either side of the tenant's own values on
  purpose. Its CA variables are hints — "here is a trust store holding the
  MITM root" — so an `env_vars` entry naming a different bundle wins, and
  costs that tenant its own egress and nobody else's. Its proxy variables
  are the chokepoint (ADR 0019), so nothing overrides them. Before #1674 the
  whole list came last, so an `env_vars` entry for one of those names was
  written and then overwritten one line later. `docs/concepts/secrets.md`
  publishes both halves of the rule.

  `opts` carries what `ConversationServer` holds: `:runtime_module`,
  `:env_credentials`, `:callback_token`, `:conversation_id` and
  `:sandbox_id`, plus `:sandbox_url` (nil before the sandbox has one) and
  `:brokered` (the pairs from the broker session, `[]` when the conversation
  is not brokered; the broker half is #1373's).
  """
  @spec build(map() | nil, Environment.t() | nil, map(), keyword()) ::
          [{String.t(), String.t()}]
  def build(agent, env, secrets, opts) do
    runtime_module = Keyword.fetch!(opts, :runtime_module)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    {ca_defaults, proxy} = split_brokered(Keyword.get(opts, :brokered, []))

    env_credentials = Keyword.fetch!(opts, :env_credentials)

    # Only the resolved kind reaches the selected provider's auth inputs.
    # Its value has already passed through Egress, including broker custody.
    auth_names =
      (agent && Managoat.Runtimes.Model.provider(agent.model))
      |> InferenceCredentials.credentials_for_provider()
      |> Enum.flat_map(&Map.fetch!(InferenceCredentials.env_aliases(), &1))

    plain = if env, do: Map.drop(env.env_vars || %{}, auth_names), else: %{}
    secrets = Map.drop(secrets, auth_names)

    sprite_env =
      (runtime_module.default_env(agent, env_credentials) || []) ++
        Fountain.Conversations.CodexChatGPT.env(runtime_module, env_credentials) ++
        CallbackKey.env(Keyword.fetch!(opts, :callback_token)) ++
        conversation_env(conversation_id) ++
        sandbox_id_env(Keyword.fetch!(opts, :sandbox_id)) ++
        sandbox_url_env(Keyword.get(opts, :sandbox_url)) ++
        otel_propagation_env() ++
        git_author_env() ++
        ca_defaults ++
        Enum.map(plain, fn {k, v} -> {to_string(k), to_string(v)} end) ++
        Enum.map(secrets, fn {k, v} -> {k, v} end) ++
        proxy

    # Register before anything can log. Provisioning writes output from its
    # very first step, and the secrets are already in the sprite by then.
    Fountain.Conversations.Redaction.put(conversation_id, sprite_env)
    sprite_env
  end

  def without_inference_inputs(model, inputs) do
    names =
      model
      |> Managoat.Runtimes.Model.provider()
      |> InferenceCredentials.credentials_for_provider()
      |> Enum.flat_map(&Map.fetch!(InferenceCredentials.env_aliases(), &1))

    Map.drop(inputs, names)
  end

  # The overridable half of the broker's pairs, and the half that is not.
  # Split by key rather than by position: `:brokered` is whatever
  # `Egress.sandbox_env/1` handed over, and a pair belonging to neither half
  # keeps the old behaviour of coming last.
  defp split_brokered(brokered) do
    ca_keys = Fountain.Broker.ca_keys()
    Enum.split_with(brokered, fn {k, _v} -> to_string(k) in ca_keys end)
  end

  # The sandbox's own HTTP endpoint, so an agent asked "what's the URL?" can
  # answer. Without it the agent has no way to know: the platform assigns the
  # URL outside the sandbox, and inside it the hostname is just "sprite".
  #
  # `SANDBOX_URL` rather than `SPRITE_URL` because the value is provider-
  # neutral; a provider that has no such endpoint simply sets nothing, and an
  # unset variable is the honest answer to "no URL".
  @spec sandbox_url_env(String.t() | nil) :: [{String.t(), String.t()}]
  def sandbox_url_env(nil), do: []
  def sandbox_url_env(url) when is_binary(url), do: [{"SANDBOX_URL", url}]

  # Inject the current conversation ID so the bundled fountain skill can
  # propagate it as X-Fountain-Parent-Conversation-Id when spawning children.
  @spec conversation_env(String.t() | nil) :: [{String.t(), String.t()}]
  def conversation_env(nil), do: []

  def conversation_env(conv_id) when is_binary(conv_id),
    do: [{"FOUNTAIN_CONVERSATION_ID", conv_id}]

  # The machine's own id, so the bundled fountain skill can put a child
  # conversation onto this same sandbox (`sandbox_id` on the create, ADR 0023).
  # Machine-scoped, not conversation-scoped: every conversation on the sandbox
  # sees the same value, so unlike the conversation id it may live on the disk.
  @spec sandbox_id_env(String.t() | nil) :: [{String.t(), String.t()}]
  def sandbox_id_env(nil), do: []

  def sandbox_id_env(sandbox_id) when is_binary(sandbox_id),
    do: [{"FOUNTAIN_SANDBOX_ID", sandbox_id}]

  @doc false
  def git_author_env do
    [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end

  # Inject the W3C trace context as TRACEPARENT into the sprite env when
  # we're inside an active OTel span. claude / codex / gemini / opencode
  # all read TRACEPARENT and tag their API calls into the trace, so a
  # turn span has every model API request as a child.
  @spec otel_propagation_env() :: [{String.t(), String.t()}]
  def otel_propagation_env do
    case Fountain.Telemetry.current_traceparent() do
      nil -> []
      tp -> [{"TRACEPARENT", tp}]
    end
  end
end
