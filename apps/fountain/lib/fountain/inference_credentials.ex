defmodule Fountain.InferenceCredentials do
  @moduledoc """
  Context for per-user inference provider credentials.

  Tenants bring their own inference tokens (ADR 0008). This context handles
  encryption (using the per-tenant DEK from `Fountain.Crypto`) and decryption
  at the boundaries — `ConversationServer` decrypts at conversation start;
  the Settings LiveView encrypts on save.

  Plaintext values are never stored. The `decrypted_for_user/2` function
  returns a map with only those providers the user has set; missing
  providers are absent from the map (not set to `nil`).
  """

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials.Credential
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo

  @providers Credential.providers()

  @doc """
  The user's **default** credential set, or `nil` if they hold none.

  An account holds one or more named sets (ADR 0053 decision 1) and exactly
  one is the default. This is what every surface reads unless something names
  another, so an account that never makes a second set behaves exactly as it
  did when this table held one row per user.

  Returns the raw schema struct (with ciphertext blobs). Use
  `decrypted_for_user/2` to get plaintext values.
  """
  @spec get_for_user(binary()) :: Credential.t() | nil
  def get_for_user(user_id) when is_binary(user_id) do
    Repo.one(from c in Credential, where: c.user_id == ^user_id and c.is_default)
  end

  @doc "Every credential set of an account, the default first and then by name."
  @spec list_sets(binary()) :: [Credential.t()]
  def list_sets(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Credential,
        where: c.user_id == ^user_id,
        order_by: [desc: c.is_default, asc: c.name]
    )
  end

  @doc "One credential set of an account by id, or `nil`. Tenant-scoped."
  @spec get_set(binary(), binary()) :: Credential.t() | nil
  def get_set(id, user_id) when is_binary(id) and is_binary(user_id) do
    if match?({:ok, _}, Ecto.UUID.dump(id)),
      do: Repo.get_by(Credential, id: id, user_id: user_id)
  end

  @doc """
  Create a named credential set holding nothing yet.

  The first set an account gets is its default, whoever asks for it: an
  account with no default is an account nothing can read a credential for.
  Every later one is not, until `set_default/2` says so.

  Audited as `inference_credential_set.created`. `opts` carries
  `:actor` / `:request_ip`.
  """
  @spec create_set(binary(), String.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def create_set(user_id, name, opts \\ []) when is_binary(user_id) do
    with_source_lock(user_id, fn ->
      attrs = %{
        user_id: user_id,
        name: name,
        is_default: is_nil(get_for_user(user_id))
      }

      %Credential{}
      |> Credential.changeset(attrs)
      |> Repo.insert()
    end)
    |> audited_set("inference_credential_set.created", opts)
  end

  @doc """
  Rename a credential set. Audited as `inference_credential_set.renamed`,
  recording both names: a set's name is a label the tenant chose, not secret
  material, and a trail that cannot say what a thing used to be called cannot
  explain a later event that names it.
  """
  @spec rename_set(Credential.t(), String.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename_set(%Credential{} = set, name, opts \\ []) do
    result =
      with_source_lock(set.user_id, fn ->
        case get_set(set.id, set.user_id) do
          nil ->
            {:error, :not_found}

          current ->
            changeset = Credential.changeset(current, %{name: name})

            case Repo.update(changeset) do
              {:ok, updated} -> {:renamed, updated, current.name}
              error -> error
            end
        end
      end)

    case result do
      {:renamed, %{name: name} = current, name} ->
        {:ok, current}

      {:renamed, updated, was} ->
        audited_set(
          {:ok, updated},
          "inference_credential_set.renamed",
          Keyword.put(opts, :metadata, %{"was" => was, "now" => updated.name})
        )

      error ->
        error
    end
  end

  @doc """
  Delete a credential set.

  Refuses the default with `{:error, :is_default}`: something has to answer
  "which credential runs this account", and an account whose last set is gone
  cannot. Promote another with `set_default/2` first, which for the last
  remaining set means there is nothing to promote and the set stays. Audited
  as `inference_credential_set.deleted`.
  """
  @spec delete_set(Credential.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, :is_default | :not_found | Ecto.Changeset.t()}
  def delete_set(%Credential{} = set, opts \\ []) do
    with_source_lock(set.user_id, fn ->
      case get_set(set.id, set.user_id) do
        nil -> {:error, :not_found}
        %Credential{is_default: true} -> {:error, :is_default}
        current -> Repo.delete(current)
      end
    end)
    |> audited_set("inference_credential_set.deleted", opts)
  end

  @doc """
  Make `set` the account's default.

  One statement, in one transaction: the partial unique index allows a single
  default per account, so clearing the old flag and setting the new one have
  to land together or the second write is rejected. Already-default is a
  no-op that records nothing — a trail that logs "changed" for a change that
  did not happen is worse than no trail (ADR 0013).

  Audited as `inference_credential_set.default_changed`.
  """
  @spec set_default(Credential.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, term()}
  def set_default(%Credential{} = set, opts \\ []) do
    result =
      with_source_lock(set.user_id, fn ->
        case get_set(set.id, set.user_id) do
          nil ->
            {:error, :not_found}

          %Credential{is_default: true} = current ->
            {:unchanged, current}

          current ->
            from(c in Credential, where: c.user_id == ^set.user_id and c.is_default)
            |> Repo.update_all(set: [is_default: false])

            current
            |> Ecto.Changeset.change(is_default: true)
            |> Repo.update()
        end
      end)

    # Audit after the transaction; an already-default request is a no-op.
    case result do
      {:unchanged, current} -> {:ok, current}
      changed -> audited_set(changed, "inference_credential_set.default_changed", opts)
    end
  end

  @doc """
  Returns a map `%{provider => plaintext}` of every credential the user has
  set, decrypted with the supplied tenant DEK. Missing providers are absent
  from the map.

  Returns `{:ok, map}` or `{:error, :decrypt_failed}` if any ciphertext fails
  to decrypt (likely a wrong DEK — should be impossible in normal operation).
  """
  @spec decrypted_for_user(binary(), binary()) ::
          {:ok, %{atom() => String.t()}} | {:error, :decrypt_failed}
  def decrypted_for_user(user_id, dek) when is_binary(user_id) and is_binary(dek),
    do: decrypted_for_set(get_for_user(user_id), dek)

  @doc """
  The same map for a named set (ADR 0053 decision 3), or for a `set_id` of
  `nil`, which is the account's default set.

  An explicit set ID must resolve through the tenant-scoped `get_set/2`.
  Missing and foreign IDs return `{:error, :inference_credential_not_found}`;
  they never select the account default. Existing conversations recover their
  persisted source binding before choosing which set ID to read.
  """
  @spec decrypted_for(binary(), binary() | nil, binary()) ::
          {:ok, %{atom() => String.t()}} | {:error, :decrypt_failed}
  def decrypted_for(user_id, nil, dek), do: decrypted_for_user(user_id, dek)

  def decrypted_for(user_id, set_id, dek) when is_binary(set_id) do
    case get_set(set_id, user_id) do
      nil -> {:error, :inference_credential_not_found}
      %Credential{} = set -> decrypted_for_set(set, dek)
    end
  end

  @doc "The decrypted map of one loaded set, or `%{}` for `nil`."
  @spec decrypted_for_set(Credential.t() | nil, binary()) ::
          {:ok, %{atom() => String.t()}} | {:error, :decrypt_failed}
  def decrypted_for_set(cred, dek) when is_binary(dek) do
    case cred do
      nil ->
        {:ok, %{}}

      %Credential{} = cred ->
        Enum.reduce_while(@providers, {:ok, %{}}, fn provider, {:ok, acc} ->
          ct_field = ciphertext_field(provider)
          ct = Map.fetch!(cred, ct_field)

          case decrypt_field(ct, dek) do
            :empty -> {:cont, {:ok, acc}}
            {:ok, plain} -> {:cont, {:ok, Map.put(acc, provider, plain)}}
            :error -> {:halt, {:error, :decrypt_failed}}
          end
        end)
    end
  end

  @doc """
  Set or clear a single provider's credential for a user.

  - `value` is a plaintext string (will be encrypted with `dek`).
  - To clear, pass `nil` or an empty string.

  Audited as `inference_credential.write` or `.delete`. These are BYO
  inference keys — secret material on par with environment and vault secrets,
  which have audited since #530. The settings LiveView and the API controller
  each recorded their own event, and the onboarding wizard, saving the same
  credential through the same function, recorded nothing (#546). Recording
  here removes the third caller's gap and the chance of a fourth.

  `opts` carries `:actor` / `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface.

  An internal `:authorize` callback may take an ownership lock and return
  `:ok` or `{:error, reason}`. It runs in the credential write transaction;
  the audit event is recorded only after that transaction commits.

  Returns `{:ok, credential}` (the updated row) or `{:error, reason}`.
  """
  @spec put_credential(binary(), binary(), atom(), String.t() | nil, keyword()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def put_credential(user_id, dek, provider, value, opts \\ [])
      when is_binary(user_id) and is_binary(dek) and provider in @providers do
    write_credential(user_id, :default, dek, provider, value, opts)
  end

  @doc """
  The same write, into a named set (ADR 0053 decision 1).

  `set` identifies a row already fetched through the tenant-scoped `get_set/2`.
  The write reloads its current state by id and tenant inside the source lock;
  a deleted row returns `{:error, :not_found}`.

  Audited as `inference_credential.write` or `.delete`, like the default-set
  write, with the set's id and name in the metadata. Which set a credential
  landed in is the question the trail could not answer before there was more
  than one, and the provider alone stops being enough the moment there is.
  """
  @spec put_credential_in(Credential.t(), binary(), atom(), String.t() | nil, keyword()) ::
          {:ok, Credential.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_credential_in(%Credential{} = set, dek, provider, value, opts \\ [])
      when is_binary(dek) and provider in @providers do
    write_credential(set.user_id, set.id, dek, provider, value, opts)
  end

  defp write_credential(user_id, selection, dek, provider, value, opts) do
    ct_field = ciphertext_field(provider)

    ciphertext =
      case value do
        nil -> nil
        "" -> nil
        plain when is_binary(plain) -> Crypto.encrypt(plain, dek)
      end

    # Principals takes its ownership row lock here, in the same transaction
    # as the write. Audit remains outside so a failed trail insert cannot
    # roll back the credential transaction (ADR 0013).
    result =
      Repo.transaction(fn ->
        lock_source(user_id)

        case Keyword.get(opts, :authorize) do
          nil ->
            :ok

          authorize ->
            case authorize.() do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
        end

        set =
          case selection do
            :default ->
              get_for_user(user_id) ||
                %Credential{user_id: user_id, name: Credential.default_name(), is_default: true}

            id ->
              get_set(id, user_id) || Repo.rollback(:not_found)
          end

        attrs =
          Map.put(
            %{user_id: user_id, name: set.name, is_default: set.is_default},
            ct_field,
            ciphertext
          )

        case set |> Credential.changeset(attrs) |> Repo.insert_or_update() do
          {:ok, credential} -> credential
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    audited(result, user_id, provider, ciphertext, opts)
  end

  # The provider name is the whole payload. The credential must never reach a
  # second table — the same rule the secret-write events follow, and the
  # reason those record a key and not a value.
  defp audited({:ok, %Credential{} = set} = ok, user_id, provider, ciphertext, opts) do
    action =
      if is_nil(ciphertext), do: "inference_credential.delete", else: "inference_credential.write"

    Audit.record(%{
      user_id: user_id,
      action: action,
      resource_type: "inference_credential",
      resource_id: Atom.to_string(provider),
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      # Which set it landed in, by id and name. The provider alone answered
      # "what changed" while an account held one row; with several it does
      # not, and a trail that cannot say which key moved cannot explain the
      # turn that ran on it. Still no value, and still no ciphertext.
      # Merged over the caller's, so a surface acting for somebody else can
      # name who asked (`Principals.put_inference_credential/5`) without this
      # function knowing about it.
      metadata:
        Map.merge(Keyword.get(opts, :metadata, %{}), %{
          "provider" => Atom.to_string(provider),
          "set_id" => set.id,
          "set" => set.name
        })
    })

    ok
  end

  defp audited(other, _user_id, _provider, _ciphertext, _opts), do: other

  # The set's name and id, never a credential: a set is a container and this
  # records what happened to the container. `Repo.transaction/1` wraps its
  # result, so unwrap before recording and hand the caller the plain shape.
  defp audited_set({:ok, %Credential{} = set}, action, opts) do
    Audit.record(%{
      user_id: set.user_id,
      action: action,
      resource_type: "inference_credential_set",
      resource_id: set.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.put(Keyword.get(opts, :metadata, %{}), "name", set.name)
    })

    {:ok, set}
  end

  defp audited_set({:error, reason}, _action, _opts), do: {:error, reason}

  @doc """
  Returns `true` if the user has at least one provider set, in **any** of
  their credential sets.

  Used by the dashboard onboarding checklist to report whether the account
  has connected a provider.

  Any set rather than the default one: this answers "has this account
  connected a provider at all", and an account whose only key lives in a set
  they made for one agent has connected one. Asking only the default would
  put the onboarding nag back in front of somebody who is already running.
  """
  @spec has_any_credential?(binary()) :: boolean()
  def has_any_credential?(user_id) when is_binary(user_id) do
    user_id |> list_sets() |> Enum.any?(&holds_any?/1)
  end

  defp holds_any?(%Credential{} = cred) do
    Enum.any?(@providers, fn p ->
      ct = Map.fetch!(cred, ciphertext_field(p))
      is_binary(ct) and byte_size(ct) > 0
    end)
  end

  @doc """
  Of `user_ids`, the ones holding at least one provider credential.

  The set form of `has_any_credential?/1`, for the admin funnel's stalled
  breakdown (#1421). A row whose every ciphertext is `nil` belongs to an
  account that cleared its last key (`put_credential/5` clears to `nil`), so
  the row existing is not the signal and this asks the same question
  `has_any_credential?/1` asks, one query instead of one account at a time.

  `_unsafe_` because it crosses tenants: it answers for whatever ids it is
  handed. The legitimate caller is a system-level aggregate — today
  `Fountain.Funnel`, which is admin-only and unscoped by construction.
  """
  @spec _unsafe_user_ids_with_credential([binary()]) :: MapSet.t(binary())
  def _unsafe_user_ids_with_credential(user_ids) when is_list(user_ids) do
    held =
      @providers
      |> Enum.map(&ciphertext_field/1)
      |> Enum.reduce(nil, fn ct, acc ->
        clause = dynamic([c], not is_nil(field(c, ^ct)))
        if acc, do: dynamic(^acc or ^clause), else: clause
      end)

    from(c in Credential, where: c.user_id in ^user_ids, distinct: true, select: c.user_id)
    |> where(^held)
    |> Repo.all()
    |> MapSet.new()
  end

  # The environment variable each static credential is exported as. A tenant
  # secret of the same name overrides it in the sandbox (`Egress`'s gate-3
  # split, published in `docs/concepts/secrets.md`), which is what the
  # resolver's tenant overrides are normalized against.
  #
  # The deployment's ChatGPT grant is deliberately absent: ADR 0052 decision 6
  # reserves `CODEX_CHATGPT_ACCESS_TOKEN` so no configuration can name it.
  # Reserve what rotates, resolve what is static (ADR 0053 decision 5).
  # `inference_credentials_env_names_test.exs` holds this table against
  # `Fountain.Broker.inference_keys/0`, which is where the same mapping is
  # used to build the placeholders.
  @env_names %{
    anthropic_api_key: "ANTHROPIC_API_KEY",
    claude_code_oauth_token: "CLAUDE_CODE_OAUTH_TOKEN",
    openai_api_key: "OPENAI_API_KEY",
    gemini_api_key: "GEMINI_API_KEY"
  }

  @doc """
  The environment variable each static credential is exported as.

  Only the four a tenant sets themselves. The managed ChatGPT grant is not
  here: configuration may not name it (ADR 0052 decision 6).
  """
  @spec env_names() :: %{atom() => String.t()}
  def env_names, do: @env_names

  @doc """
  Every supported runtime name for each static credential, canonical name first.

  OpenCode's Google adapter exports `GOOGLE_GENERATIVE_AI_API_KEY` for the
  same credential Gemini exports as `GEMINI_API_KEY`. Selection and shared
  env-file filtering use this inventory; `env_names/0` names broker bindings.
  Managed ChatGPT tokens are reserved configuration, not static aliases.
  """
  @spec env_aliases() :: %{atom() => [String.t()]}
  def env_aliases do
    Map.new(@env_names, fn
      {:gemini_api_key, name} -> {:gemini_api_key, [name, "GOOGLE_GENERATIVE_AI_API_KEY"]}
      {credential, name} -> {credential, [name]}
    end)
  end

  @doc """
  The credentials that let a model's provider run: a model `provider/id`
  names a provider; any one of these credentials serves it. Unknown
  providers (a local model, a gateway) need none — Fountain cannot know.

      iex> credentials_for_provider("anthropic")
      [:anthropic_api_key, :claude_code_oauth_token]
  """
  @spec credentials_for_provider(String.t() | nil) :: [atom()]
  def credentials_for_provider("anthropic"), do: [:anthropic_api_key, :claude_code_oauth_token]
  def credentials_for_provider("openai"), do: [:openai_api_key]
  def credentials_for_provider("google"), do: [:gemini_api_key]
  def credentials_for_provider(_), do: []

  @doc """
  What a model would be missing on this account: `nil` when one of the
  credentials its provider accepts is set (or the provider needs none),
  else `{provider, credentials}` — the provider's name and the credentials
  that would do. The onboarding wizard asks only for Anthropic; this is how
  the agent form and the API ask for the rest the first time a model needs
  them, rather than failing inside the sandbox.

  `opts` may name a `:credential_set_id`, the set this question is being
  asked about (ADR 0053 decision 3). Without one it is the account's default
  set, which is the only set that existed when every caller of this was
  written. A missing or foreign explicit set reports every credential absent;
  it never reports credentials from the account default or another tenant.
  """
  @spec missing_for_model(binary(), String.t() | nil, keyword()) ::
          nil | {String.t(), [atom()]}
  def missing_for_model(user_id, model, opts \\ []) when is_binary(user_id) do
    provider = Managoat.Runtimes.Model.provider(model)

    case credentials_for_provider(provider) do
      [] ->
        nil

      accepted ->
        status = status_for(user_id, Keyword.get(opts, :credential_set_id))
        if Enum.any?(accepted, &Map.get(status, &1, false)), do: nil, else: {provider, accepted}
    end
  end

  defp status_for(user_id, nil), do: status_for_user(user_id)

  defp status_for(user_id, set_id) do
    case get_set(set_id, user_id) do
      nil -> status_for_set(nil)
      set -> status_for_set(set)
    end
  end

  @doc """
  Resolve the credential a conversation on `model` and `runtime` runs on: the
  `Source` (scope, kind, identity, revision, and the configuration it was
  resolved against) and the credentials map the runtime is handed, with the
  selected provider's competing inputs removed and unrelated ones kept.

  One entry point, one order, under the per-user source lock
  (`with_source_lock/2`) and with no provider I/O:

  1. **Which set.** An `:expected_source` names its own `set_id`; otherwise
     the caller's `:credential_set_id`; otherwise the account default. An
     explicit id that does not resolve is `:inference_credential_not_found`,
     never a fallback.
  2. **Decrypt the set** under the tenant DEK.
  3. **Tenant overrides.** The environment's plain variables and secrets,
     then the vault's secrets (`:environment_id`, `:vault_id`), normalized by
     credential kind; two aliases that disagree inside one layer are
     `:inference_credential_conflict`; the vault wins over the environment.
  4. **Select.** An override wins over the set's value for the same kind;
     the runtime's kind precedence picks (Claude prefers OAuth, OpenCode's
     Anthropic path accepts only an API key). An empty selected value, or a
     tenant value for the provider that the runtime cannot use, is
     `:inference_credential_unusable`.
  5. **Platform policy**, only when no tenant source was selected:
     `Fountain.PlatformInference.credential_for/2`. Nothing anywhere is
     `Source.missing/0`, never an error: the sandbox still provisions, with
     nothing to call. Under an explicit `:credential_set_id`, `:missing` and
     `:platform` are refused as unusable rather than substituted.
  6. **Bind** the source's identity and revision per scope, then stamp the
     model, runtime, environment and vault.
  7. **Compare** the dumped source with `:expected_source`; a difference is
     `:inference_source_changed`.

  `opts` accepts exactly `:credential_set_id`, `:environment_id`, `:vault_id`
  and `:expected_source`; anything else raises.
  """
  @spec resolve(binary(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Source.t(), %{atom() => String.t()}} | {:error, atom()}
  def resolve(user_id, model, runtime, opts \\ []),
    do: Fountain.InferenceCredentials.Resolver.resolve(user_id, model, runtime, opts)

  @doc "Serialize source reads with credential/configuration writes, without holding locks over runtime I/O."
  def with_source_lock(user_id, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      lock_source(user_id)

      case fun.() do
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def lock_source(user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock_shared(hashtextextended('inference:platform', 0))")

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["inference:" <> user_id])

    :ok
  end

  def lock_platform_source do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('inference:platform', 0))")
    :ok
  end

  def with_platform_source_lock(fun) do
    case Repo.transaction(fn ->
           lock_platform_source()
           fun.()
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_source(user_id, %Source{} = source) do
    opts = [
      credential_set_id: source.set_id,
      environment_id: source.environment_id,
      vault_id: source.vault_id,
      expected_source: Source.dump(source)
    ]

    case resolve(user_id, source.model, source.runtime, opts) do
      {:ok, _, _} -> :ok
      {:error, _} -> {:error, :inference_source_changed}
    end
  end

  @doc """
  Returns a map `%{provider => boolean}` of which providers the user has set.
  Cheap — does not decrypt; just checks for non-nil ciphertext.
  """
  @spec status_for_user(binary()) :: %{atom() => boolean()}
  def status_for_user(user_id) when is_binary(user_id),
    do: status_for_set(get_for_user(user_id))

  @doc """
  The same map for one named set, or for `nil` (every provider false).

  What a surface showing more than the default set asks. Cheap in the same
  way: the row is already loaded and nothing is decrypted.
  """
  @spec status_for_set(Credential.t() | nil) :: %{atom() => boolean()}
  def status_for_set(nil), do: Map.new(@providers, &{&1, false})

  def status_for_set(%Credential{} = cred) do
    Map.new(@providers, fn p ->
      ct = Map.fetch!(cred, ciphertext_field(p))
      {p, is_binary(ct) and byte_size(ct) > 0}
    end)
  end

  ## Private

  defp ciphertext_field(:anthropic_api_key), do: :anthropic_api_key_ciphertext
  defp ciphertext_field(:claude_code_oauth_token), do: :claude_code_oauth_token_ciphertext
  defp ciphertext_field(:openai_api_key), do: :openai_api_key_ciphertext
  defp ciphertext_field(:gemini_api_key), do: :gemini_api_key_ciphertext

  defp decrypt_field(nil, _dek), do: :empty

  defp decrypt_field(ct, dek) when is_binary(ct) do
    case Crypto.decrypt(ct, dek) do
      {:ok, plain} -> {:ok, plain}
      :error -> :error
    end
  end
end
