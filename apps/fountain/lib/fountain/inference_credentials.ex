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

  alias Fountain.Audit
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials.Credential
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo

  @providers Credential.providers()

  @doc """
  The user's credential record, or `nil` if they hold none.

  An account holds at most one (ADR 0008; ADR 0053's 2026-10-14 addendum
  retired named sets), held to that by a unique key on `user_id`.

  Returns the raw schema struct (with ciphertext blobs). Use
  `decrypted_for_user/2` to get plaintext values.
  """
  @spec get_for_user(binary()) :: Credential.t() | nil
  def get_for_user(user_id) when is_binary(user_id) do
    Repo.get_by(Credential, user_id: user_id)
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
    do: decrypted(get_for_user(user_id), dek)

  @doc "The decrypted map of one loaded record, or `%{}` for `nil`."
  @spec decrypted(Credential.t() | nil, binary()) ::
          {:ok, %{atom() => String.t()}} | {:error, :decrypt_failed}
  def decrypted(cred, dek) when is_binary(dek) do
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
  each recorded their own event, and a third caller saving the same
  credential through the same function recorded nothing (#546). Recording
  here closes that gap and the chance of another.

  `opts` carries `:actor` / `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface.

  Returns `{:ok, credential}` (the updated row) or `{:error, reason}`.
  """
  @spec put_credential(binary(), binary(), atom(), String.t() | nil, keyword()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def put_credential(user_id, dek, provider, value, opts \\ [])
      when is_binary(user_id) and is_binary(dek) and provider in @providers do
    ct_field = ciphertext_field(provider)

    ciphertext =
      case value do
        nil -> nil
        "" -> nil
        plain when is_binary(plain) -> Crypto.encrypt(plain, dek)
      end

    # Audit remains outside so a failed trail insert cannot roll back the
    # credential transaction (ADR 0013).
    result =
      Repo.transaction(fn ->
        lock_source(user_id)
        cred = get_for_user(user_id) || %Credential{user_id: user_id}

        if unchanged?(cred, ct_field, value, dek) do
          cred
        else
          attrs = Map.put(%{user_id: user_id}, ct_field, ciphertext)

          case cred |> Credential.changeset(attrs) |> Repo.insert_or_update() do
            {:ok, credential} -> credential
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
      end)

    audited(result, user_id, provider, ciphertext, opts)
  end

  # Saving the value the record already holds changes nothing. The
  # source-lock trigger moves the record's `revision` whenever a ciphertext
  # column changes, and every encryption draws a fresh IV, so writing the same
  # token again would end every conversation bound to it with
  # `:inference_source_changed` over a credential that did not change. A
  # client that re-saves on reconnect ended a hundred conversations that way.
  defp unchanged?(%Credential{} = cred, ct_field, value, dek) when is_binary(value) do
    with stored when is_binary(stored) <- Map.get(cred, ct_field),
         {:ok, plain} <- Crypto.decrypt(stored, dek) do
      Plug.Crypto.secure_compare(plain, value)
    else
      _ -> false
    end
  end

  defp unchanged?(_cred, _ct_field, _value, _dek), do: false

  # The provider name is the whole payload. The credential must never reach a
  # second table — the same rule the secret-write events follow, and the
  # reason those record a key and not a value.
  defp audited({:ok, %Credential{}} = ok, user_id, provider, ciphertext, opts) do
    action =
      if is_nil(ciphertext), do: "inference_credential.delete", else: "inference_credential.write"

    Audit.record(%{
      user_id: user_id,
      action: action,
      resource_type: "inference_credential",
      resource_id: Atom.to_string(provider),
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      # Merged over the caller's, so a surface acting for somebody else can
      # name who asked without this function knowing about it.
      metadata:
        Map.merge(Keyword.get(opts, :metadata, %{}), %{"provider" => Atom.to_string(provider)})
    })

    ok
  end

  defp audited(other, _user_id, _provider, _ciphertext, _opts), do: other

  # The environment variable each static credential is exported as. A tenant
  # secret of the same name overrides it in the sandbox (`Egress`'s gate-3
  # split, published in `docs/concepts/secrets.md`), which is what the
  # resolver's tenant overrides are normalized against.
  #
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

  Only the four a tenant sets themselves.
  """
  @spec env_names() :: %{atom() => String.t()}
  def env_names, do: @env_names

  @doc """
  Every supported runtime name for each static credential, canonical name first.

  `GOOGLE_GENERATIVE_AI_API_KEY` is the name the removed opencode runtime read
  the credential Gemini exports as `GEMINI_API_KEY` under; an environment or
  vault that stored the key that way still supplies it, and the shared env
  file still treats it as that credential. Selection and shared
  env-file filtering use this inventory; `env_names/0` names broker bindings.
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
  that would do. This is how the agent form and the API ask for a credential
  the first time a model needs it, rather than failing inside the sandbox.
  """
  @spec missing_for_model(binary(), String.t() | nil) :: nil | {String.t(), [atom()]}
  def missing_for_model(user_id, model) when is_binary(user_id) do
    provider = Managoat.Runtimes.Model.provider(model)

    case credentials_for_provider(provider) do
      [] ->
        nil

      accepted ->
        status = status_for_user(user_id)

        if Enum.any?(accepted, &Map.get(status, &1, false)),
          do: nil,
          else: {provider, accepted}
    end
  end

  @doc """
  Resolve the credential a conversation on `model` and `runtime` runs on: the
  `Source` (scope, kind, identity, revision, and the configuration it was
  resolved against) and the credentials map the runtime is handed, with the
  selected provider's competing inputs removed and unrelated ones kept.

  One entry point, one order, under the per-user source lock
  (`with_source_lock/2`) and with no provider I/O:

  1. **Which record.** The user's credential record. An `:expected_source`
     re-validates the record it was bound to (its `set_id`, the record's id):
     one that names none reads none, and one whose record is gone reads none
     and so differs at step 8.
  2. **Decrypt the record** under the tenant DEK.
  3. **Tenant overrides.** The environment's plain variables and secrets,
     then the vault's secrets (`:environment_id`, `:vault_id`), normalized by
     credential kind; two aliases that disagree inside one layer are
     `:inference_credential_conflict`; the vault wins over the environment.
  4. **The user's own ChatGPT subscription** (ADR 0070), for a codex run on
     an OpenAI model on a brokered deployment. It wins over every API key.
  5. **Select** the user's own key. An override wins over the record's value
     for the same kind; the runtime's kind precedence picks (Claude prefers
     OAuth). An empty selected value, or a tenant value for the provider
     that the runtime cannot use, is `:inference_credential_unusable`.
  6. **The deployment's**, only when the user has nothing for the provider:
     first the deployment's ChatGPT subscription, on the same terms as
     step 4, then `Fountain.PlatformInference.key_for/1` (brokered only).
     The user's own key wins over both (ADR 0070, amended 2026-10-14,
     #2662). Nothing anywhere is `Source.missing/0`, never an error: the
     sandbox still provisions, with nothing to call.
  7. **Bind** the source's identity and revision per scope, then stamp the
     model, runtime, environment and vault.
  8. **Compare** the dumped source with `:expected_source`; a difference is
     `:inference_source_changed`, or `:chatgpt_reconnect_required` when the
     pinned ChatGPT subscription no longer serves (ADR 0070).

  `opts` accepts exactly `:environment_id`, `:vault_id` and
  `:expected_source`; anything else raises.
  """
  @spec resolve(binary(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Source.t(), %{atom() => String.t()}}
          | {:error, atom()}
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
    lock_tenant_source(user_id)
  end

  @doc """
  The tenant half of `lock_source/1` alone: what a write to something only
  this user's resolution reads takes. The platform key is deliberately not
  taken, not even shared: PostgreSQL queues a new shared request behind a
  waiting exclusive one, so one user's write would stall behind an admin key
  write or an account deletion, and they behind it.

  A transaction holding this must not go on to ask for the platform key.
  The order everywhere is platform, then tenant.

  The key is built from the canonical spelling of the id, because the
  trigger builds its own from `uuid::text`: another spelling would be
  another lock. What is not a UUID raises, so no string can spell the
  platform's key through here.
  """
  def lock_tenant_source(user_id) when is_binary(user_id) do
    key = "inference:" <> Ecto.UUID.cast!(user_id)
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])

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
      environment_id: source.environment_id,
      vault_id: source.vault_id,
      expected_source: Source.dump(source)
    ]

    case resolve(user_id, source.model, source.runtime, opts) do
      {:ok, _, _} -> :ok
      {:error, :chatgpt_reconnect_required} = error -> error
      {:error, _} -> {:error, :inference_source_changed}
    end
  end

  @doc """
  Returns a map `%{provider => boolean}` of which providers the user has set.
  Cheap — does not decrypt; just checks for non-nil ciphertext.
  """
  @spec status_for_user(binary()) :: %{atom() => boolean()}
  def status_for_user(user_id) when is_binary(user_id),
    do: status(get_for_user(user_id))

  @doc """
  The same map for a loaded record, or for `nil` (every provider false).
  Cheap in the same way: nothing is decrypted.
  """
  @spec status(Credential.t() | nil) :: %{atom() => boolean()}
  def status(nil), do: Map.new(@providers, &{&1, false})

  def status(%Credential{} = cred) do
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
