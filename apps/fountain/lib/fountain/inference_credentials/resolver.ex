defmodule Fountain.InferenceCredentials.Resolver do
  @moduledoc false
  alias Fountain.{Crypto, Environments, InferenceCredentials, PlatformInference, Repo, Vaults}
  alias Fountain.InferenceCredentials.Source

  @options [:credential_set_id, :environment_id, :vault_id, :expected_source]

  defmodule Inputs do
    @moduledoc false
    # What selection runs on once the rows are loaded and decrypted: the
    # model's provider, the set's own values by kind, and the
    # tenant's overrides, normalized to `kind => {value, identity, revision}`.
    @enforce_keys [:provider, :own, :overrides]
    defstruct [:provider, :own, :overrides]
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

      # The platform's subscription, like its key, never serves a run that
      # names its set explicitly (`usable/2`).
      explicit_set? = is_nil(expected) and is_binary(Keyword.get(opts, :credential_set_id))

      with :ok <- require_set(set_id, set),
           {:ok, dek} <- Crypto.load_tenant_key(user_id),
           {:ok, own} <- InferenceCredentials.decrypted_for_set(set, dek),
           {:ok, overrides} <- overrides(user_id, dek, opts, provider),
           {:ok, source, creds} <-
             chatgpt(user_id, provider, runtime, own, not explicit_set?) ||
               select(%Inputs{
                 provider: provider,
                 own: own,
                 overrides: overrides
               }),
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

  # A codex run on an OpenAI model takes a ChatGPT subscription first (ADR
  # 0070): the user's own, else the deployment's, and only an API key after
  # both. Only on a brokered deployment: the access token goes to the broker
  # and the sandbox gets a placeholder (`Fountain.Conversations.CodexChatGPT`);
  # without a broker it would land in the sandbox in the clear. A read and a
  # decrypt, no provider I/O: this runs under the source lock. nil when no
  # subscription serves, and the ordinary selection runs.
  defp chatgpt(user_id, "openai", "codex", own, platform?) do
    if Fountain.Broker.configured?() do
      case Fountain.ChatGPT.serving(user_id, platform?) do
        {:ok, owner, sub, token} ->
          {scope, identity} =
            case owner do
              {:user, id} -> {Source.grant(), "chatgpt:" <> id}
              :platform -> {Source.platform(), "platform:chatgpt"}
            end

          source = %{
            scope
            | kind: :codex_chatgpt_access_token,
              identity: identity,
              revision: sub.account_id
          }

          {:ok, source,
           own |> drop_competitors("openai") |> Map.put(:codex_chatgpt_access_token, token)}

        :none ->
          nil
      end
    end
  end

  defp chatgpt(_user_id, _provider, _runtime, _own, _platform?), do: nil

  defp require_set(nil, _), do: :ok
  defp require_set(_, nil), do: {:error, :inference_credential_not_found}
  defp require_set(_, _), do: :ok

  defp usable(id, %Source{scope: scope}) when scope in [:missing, :platform] and is_binary(id),
    do: {:error, :inference_credential_unusable}

  defp usable(_, _), do: :ok

  def matches(nil, _), do: :ok

  # A conversation bound to a subscription that no longer serves (removed,
  # revoked, or linked to another account) is told to reconnect, not that its
  # source changed: linking it again is the fix.
  def matches(expected, source) do
    cond do
      expected == Source.dump(source) ->
        :ok

      reconnect?(expected, source) ->
        {:error, :chatgpt_reconnect_required}

      true ->
        {:error, :inference_source_changed}
    end
  end

  defp reconnect?(expected, source) do
    case Source.chatgpt_owner(expected) do
      {owner, _account} ->
        Source.chatgpt_owner(source) == nil or not Fountain.ChatGPT.active?(owner)

      nil ->
        false
    end
  end

  # Overrides win over the set's value for the same kind; the runtime's kind
  # precedence picks. An empty selected value, or a tenant value for the
  # provider that the runtime cannot use, is unusable rather than a fall
  # through to the platform.
  defp select(%Inputs{provider: provider, own: own, overrides: overrides}) do
    accepted = accepted(provider)

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
        platform(provider, own)
    end
  end

  defp accepted("anthropic"), do: [:claude_code_oauth_token, :anthropic_api_key]
  defp accepted(provider), do: InferenceCredentials.credentials_for_provider(provider)

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
  defp platform(provider, own) do
    case PlatformInference.key_for(provider) do
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
        _ when source.kind == :codex_chatgpt_access_token -> {source.identity, source.revision}
        :platform -> PlatformInference.reference(source.kind, creds, dek)
        scope -> {Atom.to_string(scope), "1"}
      end

    %{source | identity: identity, revision: revision, set_id: set && set.id}
  end
end
