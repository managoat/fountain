defmodule Fountain.InferenceCredentials.Resolver do
  @moduledoc false
  alias Fountain.{Crypto, Environments, InferenceCredentials, PlatformInference, Repo, Vaults}
  alias Fountain.InferenceCredentials.Source

  @options [:credential_set_id, :environment_id, :vault_id, :expected_source]

  defmodule Inputs do
    @moduledoc false
    # What selection runs on once the rows are loaded and decrypted: the
    # model's provider, the runtime, the set's own values by kind, and the
    # tenant's overrides, normalized to `kind => {value, identity, revision}`.
    @enforce_keys [:provider, :runtime, :own, :overrides]
    defstruct [:provider, :runtime, :own, :overrides]
  end

  def resolve(user_id, model, runtime, opts) do
    opts = Keyword.validate!(opts, @options)

    InferenceCredentials.with_source_lock(user_id, fn ->
      expected = Keyword.get(opts, :expected_source)
      set_id = if expected, do: expected["set_id"], else: Keyword.get(opts, :credential_set_id)

      set =
        cond do
          set_id -> InferenceCredentials.get_set(set_id, user_id)
          expected -> nil
          true -> InferenceCredentials.get_for_user(user_id)
        end

      provider = Managoat.Runtimes.Model.provider(model)

      with :ok <- require_set(set_id, set),
           {:ok, dek} <- Crypto.load_tenant_key(user_id),
           {:ok, own} <- InferenceCredentials.decrypted_for_set(set, dek),
           {:ok, overrides} <- overrides(user_id, dek, opts, provider),
           {:ok, source, creds} <-
             select(%Inputs{provider: provider, runtime: runtime, own: own, overrides: overrides}),
           :ok <-
             usable(if(expected, do: nil, else: Keyword.get(opts, :credential_set_id)), source),
           source <- bind(source, set, creds, dek),
           source <- %{
             source
             | model: model,
               runtime: runtime,
               environment_id: Keyword.get(opts, :environment_id),
               vault_id: Keyword.get(opts, :vault_id)
           },
           :ok <- matches(expected, source) do
        {:ok, source, creds}
      end
    end)
  end

  defp require_set(nil, _), do: :ok
  defp require_set(_, nil), do: {:error, :inference_credential_not_found}
  defp require_set(_, _), do: :ok

  defp usable(id, %Source{scope: scope}) when scope in [:missing, :platform] and is_binary(id),
    do: {:error, :inference_credential_unusable}

  defp usable(_, _), do: :ok

  def matches(nil, _), do: :ok

  def matches(expected, source) do
    if expected == Source.dump(source), do: :ok, else: {:error, :inference_source_changed}
  end

  # Overrides win over the set's value for the same kind; the runtime's kind
  # precedence picks. An empty selected value, or a tenant value for the
  # provider that the runtime cannot use, is unusable rather than a fall
  # through to the platform.
  defp select(%Inputs{provider: provider, runtime: runtime, own: own, overrides: overrides}) do
    accepted = accepted(provider, runtime)

    entries =
      Map.merge(Map.new(own, fn {kind, value} -> {kind, {value, nil, nil}} end), overrides)

    kind = Enum.find(accepted, &Map.has_key?(entries, &1))

    cond do
      accepted == [] ->
        {:ok, Source.none(), own}

      kind && elem(entries[kind], 0) in [nil, ""] ->
        {:error, :inference_credential_unusable}

      kind ->
        {value, identity, revision} = entries[kind]
        source = if identity, do: Source.tenant_secret(), else: Source.credential()
        creds = Map.put(drop_competitors(own, provider), kind, value)
        {:ok, %{source | kind: kind, identity: identity, revision: revision}, creds}

      Enum.any?(
        InferenceCredentials.credentials_for_provider(provider),
        &Map.has_key?(entries, &1)
      ) ->
        {:error, :inference_credential_unusable}

      true ->
        platform(provider, runtime, own)
    end
  end

  defp accepted("anthropic", "opencode"), do: [:anthropic_api_key]
  defp accepted("anthropic", _), do: [:claude_code_oauth_token, :anthropic_api_key]
  defp accepted(provider, _), do: InferenceCredentials.credentials_for_provider(provider)

  defp normalize(values, references, kinds) do
    Enum.reduce_while(Map.take(InferenceCredentials.env_aliases(), kinds), {:ok, %{}}, fn {kind,
                                                                                           names},
                                                                                          {:ok,
                                                                                           acc} ->
      candidates = for name <- names, Map.has_key?(values, name), do: {name, values[name]}

      case Enum.uniq_by(candidates, &elem(&1, 1)) do
        [] ->
          {:cont, {:ok, acc}}

        [{name, value}] ->
          {identity, revision} = Map.get(references, name, {name, nil})
          {:cont, {:ok, Map.put(acc, kind, {value, identity, revision})}}

        _ ->
          {:halt, {:error, :inference_credential_conflict}}
      end
    end)
  end

  defp drop_competitors(creds, provider),
    do: Map.drop(creds, InferenceCredentials.credentials_for_provider(provider))

  # Platform policy, only when no tenant source was selected: one question
  # to the module that owns the deployment's credentials.
  defp platform(provider, runtime, own) do
    case PlatformInference.credential_for(provider, runtime) do
      {:ok, kind, value} ->
        {:ok, %{Source.platform() | kind: kind},
         Map.put(drop_competitors(own, provider), kind, value)}

      :none ->
        {:ok, Source.missing(), own}
    end
  end

  # The tenant's overrides for the provider's kinds: the environment's plain
  # variables and secrets, then the vault's secrets, each layer normalized on
  # its own (two aliases that disagree inside one layer conflict) and the
  # vault merged over the environment.
  defp overrides(user_id, dek, opts, provider) do
    env =
      if id = Keyword.get(opts, :environment_id), do: Environments.get_environment(id, user_id)

    vault = if id = Keyword.get(opts, :vault_id), do: Vaults.get_vault(id, user_id)
    plain = if env, do: env.env_vars || %{}, else: %{}

    refs =
      if env,
        do:
          Map.new(plain, fn {name, _value} ->
            {name, {"environment:" <> env.id <> ":" <> name, env.inference_revision}}
          end),
        else: %{}

    {env_values, env_refs} = add_secrets(plain, refs, env, :environment, dek)
    {vault_values, vault_refs} = add_secrets(%{}, %{}, vault, :vault, dek)
    kinds = InferenceCredentials.credentials_for_provider(provider)

    with {:ok, environment} <- normalize(env_values, env_refs, kinds),
         {:ok, vault} <- normalize(vault_values, vault_refs, kinds) do
      {:ok, Map.merge(environment, vault)}
    end
  end

  defp add_secrets(values, refs, nil, _, _), do: {values, refs}

  defp add_secrets(values, refs, parent, type, dek) do
    rows = Repo.preload(parent, :secrets).secrets

    Enum.reduce(rows, {values, refs}, fn row, {values, refs} ->
      case Crypto.decrypt(row.value_ciphertext, dek) do
        {:ok, value} ->
          reference = {"#{type}:#{parent.id}:#{row.id}", row.inference_revision}
          {Map.put(values, row.key, value), Map.put(refs, row.key, reference)}

        :error ->
          {Map.put(values, row.key, nil), refs}
      end
    end)
  end

  defp bind(source, set, creds, dek) do
    {identity, revision} =
      case source.scope do
        :credential -> {"credential:#{set.id}:#{source.kind}", set.revision}
        :tenant_secret -> {source.identity, source.revision}
        :platform -> PlatformInference.reference(source.kind, creds, dek)
        scope -> {Atom.to_string(scope), "1"}
      end

    %{source | identity: identity, revision: revision, set_id: set && set.id}
  end
end
