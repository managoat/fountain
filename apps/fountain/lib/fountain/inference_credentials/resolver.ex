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
    # `grant` is the ChatGPT subscription the set names (ADR 0060 decision 2):
    # `:none`, or `{:named, id, view}` where the view is
    # `ChatGPTAccounts.get_for_user/2`'s and is `nil` when the owner holds no
    # such grant.
    @enforce_keys [:provider, :runtime, :own, :overrides, :grant]
    defstruct [:provider, :runtime, :own, :overrides, :grant]
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
             select(%Inputs{
               provider: provider,
               runtime: runtime,
               own: own,
               overrides: overrides,
               grant: named_grant(set, provider, user_id)
             })
             |> pinned_elsewhere(expected),
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

  # The grant a set names, read only for a model a subscription can serve, so
  # every other resolution costs nothing more than it did. Scoped by the
  # owner a second time, after the changeset and the foreign key: a row that
  # somehow names a grant its owner does not hold is `{:named, id, nil}`, and
  # that resolves to an error, never to another credential. Metadata only, as
  # everything under the source lock must be: no decrypt, no provider I/O,
  # and no renewal (`Fountain.ChatGPTAccounts`, "The source lock").
  defp named_grant(%{chatgpt_grant_id: id}, "openai", user_id) when is_binary(id) do
    case Fountain.ChatGPTAccounts.get_for_user(id, user_id) do
      {:ok, view} -> {:named, id, view}
      {:error, :not_found} -> {:named, id, nil}
    end
  end

  defp named_grant(_set, _provider, _user_id), do: :none

  # A conversation pinned to something else (the set's API key, or another
  # grant the set named then) has not lost a subscription; its source
  # changed, and that is what it is told.
  defp pinned_elsewhere({:error, {:chatgpt_grant_unusable, %{grant_id: id}}} = error, expected)
       when is_map(expected) do
    if expected["scope"] == "grant" and expected["grant_id"] == id,
      do: error,
      else: {:error, :inference_source_changed}
  end

  defp pinned_elsewhere(result, _expected), do: result

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

  # A codex run on a set that names a subscription runs on that subscription
  # or does not run (ADR 0060 decision 4, 0053 decision 5 rule 2). This comes
  # before the overrides on purpose: an `OPENAI_API_KEY` in the environment
  # or the vault does not outrank the grant, the set's own key is not a
  # fallback, another of the user's grants is not, and the platform is not.
  # The key is dropped from what the runtime is handed so codex cannot log in
  # with it beside the grant. No bearer is put there: a grant's token never
  # travels in the credentials map (ADR 0052 decision 6).
  defp select(%Inputs{provider: "openai", runtime: "codex", grant: {:named, id, view}, own: own}) do
    case grant_state(view) do
      :ok ->
        source = %{
          Source.grant()
          | kind: :codex_chatgpt_access_token,
            grant_id: view.grant_id,
            generation: view.generation
        }

        {:ok, source, drop_competitors(own, "openai")}

      {reason, until} ->
        {:error,
         {:chatgpt_grant_unusable,
          %{grant_id: id, name: view && view.name, reason: reason, until: until}}}
    end
  end

  # Every other OpenAI consumer needs a key, and the grant is not one (ADR
  # 0060 decision 2). With a key, from the set or an override, the ordinary
  # selection below serves it. With none the answer is `:missing` and never
  # the platform's key: the account chose its own OpenAI source for this set.
  defp select(%Inputs{provider: "openai", grant: {:named, _, _}, own: own, overrides: overrides})
       when not is_map_key(own, :openai_api_key) and not is_map_key(overrides, :openai_api_key),
       do: {:ok, Source.missing(), own}

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

  # From the row's metadata alone. A token inside its refresh margin, or past
  # it, is usable here as the platform grant's is: renewing is the turn's
  # business, outside this lock. Exhaustion is read but never yet written for
  # a user's grant (ADR 0060 stage 5).
  defp grant_state(nil), do: {:not_found, nil}

  defp grant_state(view) do
    cond do
      # The same rule as the platform grant's (`PlatformInference.credential_for/2`):
      # with no broker the token would land in the sandbox in the clear.
      not Fountain.Broker.configured?() -> {:broker_required, nil}
      view.status == "disconnected" -> {:disconnected, nil}
      view.status == "revoked" -> {:revoked, nil}
      view.status == "expired" -> {:expired, nil}
      view.status != "active" or view.kind != "chatgpt" -> {:reconnect_required, nil}
      not view.refreshable or view.account_id in [nil, ""] -> {:reconnect_required, nil}
      match?(%DateTime{}, view.exhausted_until) -> {:exhausted, view.exhausted_until}
      true -> :ok
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
        :grant -> {"chatgpt_grant:" <> source.grant_id, source.generation}
        scope -> {Atom.to_string(scope), "1"}
      end

    %{source | identity: identity, revision: revision, set_id: set && set.id}
  end
end
