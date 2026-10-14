defmodule Fountain.InferenceCredentials.Resolver do
  @moduledoc false
  alias Fountain.{Crypto, Environments, InferenceCredentials, PlatformInference, Repo, Vaults}
  alias Fountain.InferenceCredentials.Source

  @options [:environment_id, :vault_id, :expected_source]

  defmodule Inputs do
    @moduledoc false
    # What selection runs on once the rows are loaded and decrypted: the
    # model's provider, the user's own values by kind, and the
    # tenant's overrides, normalized to `kind => {value, identity, revision}`.
    @enforce_keys [:provider, :own, :overrides]
    defstruct [:provider, :own, :overrides]
  end

  def resolve(user_id, model, runtime, opts) do
    opts = Keyword.validate!(opts, @options)

    InferenceCredentials.with_source_lock(user_id, fn ->
      expected = Keyword.get(opts, :expected_source)
      provider = Managoat.Runtimes.Model.provider(model)

      with {:ok, record} <- record(user_id, expected),
           {:ok, dek} <- Crypto.load_tenant_key(user_id),
           {:ok, own} <- InferenceCredentials.decrypted(record, dek),
           {:ok, overrides} <- overrides(user_id, dek, opts, provider),
           {:ok, source, creds} <-
             pick(user_id, provider, runtime, %Inputs{
               provider: provider,
               own: own,
               overrides: overrides
             }),
           source <- bind(source, record, creds, dek),
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

  # A new selection reads the user's record. A re-validation reads the record
  # its stored source was bound to: the stored `set_id` (a name kept from the
  # retired named sets, so that every stored source still compares equal) is
  # that record's id. A source bound to no record reads none, so a key added
  # since does not change it; one whose record is gone is not found.
  defp record(user_id, nil), do: {:ok, InferenceCredentials.get_for_user(user_id)}

  defp record(user_id, expected) do
    case expected["set_id"] do
      nil ->
        {:ok, nil}

      id ->
        case InferenceCredentials.get_for_user(user_id) do
          %{id: ^id} = record -> {:ok, record}
          _ -> {:error, :inference_credential_not_found}
        end
    end
  end

  # The order, the user's own credential first (ADR 0008; ADR 0070 as amended
  # 2026-10-14, #2662): the user's own ChatGPT subscription, then the user's
  # own key (the record, an environment's or a vault's), then the deployment's
  # subscription, then the platform key. Both subscriptions apply only to a
  # codex run on an OpenAI model on a brokered deployment.
  defp pick(user_id, provider, runtime, %Inputs{own: own} = inputs) do
    with nil <- chatgpt({:user, user_id}, provider, runtime, own),
         :no_tenant_source <- select(inputs) do
      chatgpt(:platform, provider, runtime, own) || platform(provider, own)
    end
  end

  # A codex run on an OpenAI model can run on `owner`'s ChatGPT subscription
  # (ADR 0070). Only on a brokered deployment: the access token goes to the
  # broker and the sandbox gets a placeholder
  # (`Fountain.Conversations.CodexChatGPT`); without a broker it would land in
  # the sandbox in the clear. A read and a decrypt, no provider I/O: this runs
  # under the source lock. nil when that subscription does not serve.
  defp chatgpt(owner, "openai", "codex", own) do
    if Fountain.Broker.configured?() do
      case Fountain.ChatGPT.serving(owner) do
        {:ok, sub, token} ->
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

  defp chatgpt(_owner, _provider, _runtime, _own), do: nil

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

  # Asks the pinned subscription itself rather than what replaced it: since
  # the user's own key outranks the deployment's subscription (#2662), a
  # conversation on that subscription can lose it to a key while the
  # subscription still serves. That is a source change, and linking again
  # would not help.
  defp reconnect?(expected, _source) do
    case Source.chatgpt_owner(expected) do
      {owner, _account} -> Fountain.ChatGPT.serving(owner) == :none
      nil -> false
    end
  end

  # Overrides win over the record's value for the same kind; the runtime's kind
  # precedence picks. An empty selected value, or a tenant value for the
  # provider that the runtime cannot use, is unusable rather than a fall
  # through to the deployment. `:no_tenant_source` when the user has nothing
  # for the provider, and `pick/4` asks the deployment.
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
        :no_tenant_source
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
  #
  # Only on a brokered deployment (ADR 0038, 2026-10-14 addendum), the same
  # rule the deployment's ChatGPT subscription follows above: without a
  # broker the key would be handed to the sandbox in the clear, where any
  # process the tenant runs can read it and spend it anywhere. The tenant's
  # own credentials are theirs to expose and are not gated.
  defp platform(provider, own) do
    with true <- PlatformInference.offered?(),
         {:ok, kind, value} <- PlatformInference.key_for(provider) do
      {:ok, %{Source.platform() | kind: kind},
       Map.put(drop_competitors(own, provider), kind, value)}
    else
      _unbrokered_or_none -> {:ok, Source.missing(), own}
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

  # `set_id` is the credential record's id. The key keeps its set-era name:
  # every stored source is compared whole with a fresh dump, so renaming it
  # would end every conversation admitted before the rename.
  defp bind(source, record, creds, dek) do
    {identity, revision} =
      case source.scope do
        :credential -> {"credential:#{record.id}:#{source.kind}", record.revision}
        :tenant_secret -> {source.identity, source.revision}
        _ when source.kind == :codex_chatgpt_access_token -> {source.identity, source.revision}
        :platform -> PlatformInference.reference(source.kind, creds, dek)
        scope -> {Atom.to_string(scope), "1"}
      end

    %{source | identity: identity, revision: revision, set_id: record && record.id}
  end
end
