defmodule Fountain.InferenceCredentials.Resolver do
  @moduledoc false
  import Ecto.Query
  alias Fountain.{Crypto, Environments, InferenceCredentials, Repo, Vaults}
  alias Fountain.InferenceCredentials.Source

  def resolve(user_id, model, runtime, opts) do
    InferenceCredentials.with_source_lock(user_id, fn ->
      expected = Keyword.get(opts, :expected_source)
      set_id = if expected, do: expected["set_id"], else: Keyword.get(opts, :credential_set_id)

      set =
        cond do
          set_id -> InferenceCredentials.get_set(set_id, user_id)
          expected -> nil
          true -> InferenceCredentials.get_for_user(user_id)
        end

      with :ok <- require_set(set_id, set),
           {:ok, dek} <- Crypto.load_tenant_key(user_id),
           {:ok, own} <- InferenceCredentials.decrypted_for_set(set, dek),
           {:ok, overrides} <- overrides(user_id, dek, opts, model),
           {:ok, source, creds} <-
             select(
               model,
               own,
               runtime,
               Keyword.merge(opts,
                 override_entries: overrides,
                 refresh: false,
                 brokered: Fountain.Broker.configured?()
               )
             ),
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

  def select(model, own, runtime, opts) do
    provider = Managoat.Runtimes.Model.provider(model)
    accepted = accepted(provider, runtime)

    with {:ok, overrides} <- selected_overrides(opts, provider) do
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
          platform(provider, runtime, own, opts)
      end
    end
  end

  def accepted("anthropic", "opencode"), do: [:anthropic_api_key]
  def accepted("anthropic", _), do: [:claude_code_oauth_token, :anthropic_api_key]
  def accepted(provider, _), do: InferenceCredentials.credentials_for_provider(provider)

  defp selected_overrides(opts, provider) do
    case Keyword.fetch(opts, :override_entries) do
      {:ok, entries} ->
        {:ok, entries}

      :error ->
        values = Keyword.get(opts, :overrides, %{})

        normalize(
          values,
          Map.new(values, fn {name, _} -> {name, {name, nil}} end),
          InferenceCredentials.credentials_for_provider(provider)
        )
    end
  end

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

  defp platform(provider, runtime, own, opts) do
    selected =
      if provider == "openai" and runtime == "codex" and Keyword.get(opts, :brokered, true) do
        case Fountain.ChatGPTAccounts.platform_credential(
               refresh: Keyword.get(opts, :refresh, true)
             ) do
          {:ok, token} -> {:ok, :codex_chatgpt_access_token, token}
          :none -> Fountain.PlatformInference.key_for(provider)
        end
      else
        Fountain.PlatformInference.key_for(provider)
      end

    case selected do
      {:ok, kind, value} ->
        {:ok, %{Source.platform() | kind: kind},
         Map.put(drop_competitors(own, provider), kind, value)}

      :none ->
        {:ok, Source.missing(), own}
    end
  end

  defp overrides(user_id, dek, opts, model) do
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

    with {:ok, environment} <-
           normalize(
             env_values,
             env_refs,
             InferenceCredentials.credentials_for_provider(
               Managoat.Runtimes.Model.provider(model)
             )
           ),
         {:ok, vault} <-
           normalize(
             vault_values,
             vault_refs,
             InferenceCredentials.credentials_for_provider(
               Managoat.Runtimes.Model.provider(model)
             )
           ) do
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
        :platform -> platform_reference(source.kind, creds, dek)
        scope -> {Atom.to_string(scope), "1"}
      end

    %{source | identity: identity, revision: revision, set_id: set && set.id}
  end

  defp platform_reference(:codex_chatgpt_access_token, _creds, _dek) do
    # Ownership and generation are read from the same null-owner grant used
    # by the platform policy. Token refresh does not replace this identity.
    grant =
      Repo.one(
        from a in Fountain.PlatformChatGPT.Account,
          where: is_nil(a.user_id) and a.status == "active"
      )

    {"platform:chatgpt:#{grant.id}", grant.generation}
  end

  defp platform_reference(kind, creds, dek) do
    provider =
      case kind do
        :anthropic_api_key -> "anthropic"
        :openai_api_key -> "openai"
        :gemini_api_key -> "google"
      end

    case Repo.get(Fountain.PlatformInference.Key, provider) do
      %{ciphertext: ciphertext, revision: revision} ->
        case Crypto.decrypt_platform(ciphertext) do
          {:ok, _} -> {"platform:stored:#{provider}", revision}
          _ -> {"platform:environment:#{provider}", digest(dek, creds[kind])}
        end

      nil ->
        {"platform:environment:#{provider}", digest(dek, creds[kind])}
    end
  end

  # Keyed revision markers for plaintext configuration are not bearer values
  # and do not permit an offline dictionary attack. Ownership comes from the
  # scoped source row; the marker only detects replacement of its value.
  defp digest(dek, value),
    do: :crypto.mac(:hmac, :sha256, dek, to_string(value)) |> Base.encode16(case: :lower)
end
