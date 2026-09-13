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
  Fetch the credentials row for a user, or `nil` if absent.

  Returns the raw schema struct (with ciphertext blobs). Use
  `decrypted_for_user/2` to get plaintext values.
  """
  @spec get_for_user(binary()) :: Credential.t() | nil
  def get_for_user(user_id) when is_binary(user_id) do
    Repo.one(from c in Credential, where: c.user_id == ^user_id)
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
  def decrypted_for_user(user_id, dek) when is_binary(user_id) and is_binary(dek) do
    case get_for_user(user_id) do
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

  Returns `{:ok, credential}` (the updated row) or `{:error, changeset}`.
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

    existing = get_for_user(user_id) || %Credential{user_id: user_id}

    attrs = %{user_id: user_id} |> Map.put(ct_field, ciphertext)

    existing
    |> Credential.changeset(attrs)
    |> Repo.insert_or_update()
    |> audited(user_id, provider, ciphertext, opts)
  end

  # The provider name is the whole payload. The credential must never reach a
  # second table — the same rule the secret-write events follow, and the
  # reason those record a key and not a value.
  defp audited({:ok, _cred} = ok, user_id, provider, ciphertext, opts) do
    action =
      if is_nil(ciphertext), do: "inference_credential.delete", else: "inference_credential.write"

    Audit.record(%{
      user_id: user_id,
      action: action,
      resource_type: "inference_credential",
      resource_id: Atom.to_string(provider),
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"provider" => Atom.to_string(provider)}
    })

    ok
  end

  defp audited(other, _user_id, _provider, _ciphertext, _opts), do: other

  @doc """
  Returns `true` if the user has at least one provider set.

  Used by the onboarding wizard to gate the next step, and by the
  conversation-start flow to give a clearer error than "auth failed
  in the sprite."
  """
  @spec has_any_credential?(binary()) :: boolean()
  def has_any_credential?(user_id) when is_binary(user_id) do
    case get_for_user(user_id) do
      nil ->
        false

      %Credential{} = cred ->
        Enum.any?(@providers, fn p ->
          ct = Map.fetch!(cred, ciphertext_field(p))
          is_binary(ct) and byte_size(ct) > 0
        end)
    end
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
  # split, published in `docs/concepts/secrets.md`), which is what
  # `select/4`'s `:secret_keys` reads.
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
  """
  @spec missing_for_model(binary(), String.t() | nil) :: nil | {String.t(), [atom()]}
  def missing_for_model(user_id, model) when is_binary(user_id) do
    provider = Managoat.Runtimes.Model.provider(model)

    case credentials_for_provider(provider) do
      [] ->
        nil

      accepted ->
        status = status_for_user(user_id)
        if Enum.any?(accepted, &Map.get(status, &1, false)), do: nil, else: {provider, accepted}
    end
  end

  @doc """
  Whether the tenant has a credential of their own that would run this model.

  True also when the model's provider needs none at all (a local model, a
  gateway): there is nothing missing, which is the same answer
  `missing_for_model/2` gives.

  `opts` may name a launch's `:environment_id` and `:vault_id`. With either,
  a secret of theirs named after a credential the provider accepts counts as
  the tenant's own, because it is what will serve the conversation (ADR 0053
  decision 5). With neither — every caller that has no launch in hand — this
  is exactly the row question it has always been, and runs no extra query.
  """
  @spec has_own?(binary(), String.t() | nil, keyword()) :: boolean()
  def has_own?(user_id, model, opts \\ []) when is_binary(user_id) do
    case missing_for_model(user_id, model) do
      nil -> true
      {_provider, accepted} -> shadowed?(accepted, secret_keys(user_id, opts))
    end
  end

  @doc """
  Which of the static credential names this launch's environment or vault
  defines.

  Names, never values, and only the four `env_names/0` knows: this answers
  "would a tenant secret serve this conversation", which is what keeps a
  tenant who brought their own key off the platform ledger and out of the
  deployment's daily ceiling.

  Scoped by joining the owning row to `user_id`, so an id belonging to
  another tenant contributes nothing rather than leaking the fact that it
  exists. Both ids absent is the common case and runs no query.
  """
  @spec secret_keys(binary(), keyword()) :: [String.t()]
  def secret_keys(user_id, opts \\ []) when is_binary(user_id) do
    env_id = Keyword.get(opts, :environment_id)
    vault_id = Keyword.get(opts, :vault_id)
    names = Map.values(@env_names)

    env_keys =
      if env_id do
        Repo.all(
          from s in Fountain.Environments.Secret,
            join: e in assoc(s, :environment),
            where: e.user_id == ^user_id and s.environment_id == ^env_id and s.key in ^names,
            select: s.key
        )
      else
        []
      end

    vault_keys =
      if vault_id do
        Repo.all(
          from s in Fountain.Vaults.VaultSecret,
            join: v in assoc(s, :vault),
            where: v.user_id == ^user_id and s.vault_id == ^vault_id and s.key in ^names,
            select: s.key
        )
      else
        []
      end

    Enum.uniq(env_keys ++ vault_keys)
  end

  @doc """
  Which credential a conversation on `model` runs on (#1388, ADR 0038
  decision 3). **This is the whole selection rule**, and it is one function so
  that the two paths a credential reaches a sandbox by cannot disagree.

    * `{:ok, %Source{origin: :own}, creds}` — the tenant has a credential the
      model's provider accepts, or the provider needs none. `creds` is what
      came in, untouched. The source's `scope` says which of the two it was.
    * `{:ok, %Source{origin: :platform}, creds}` — the tenant has none and
      this deployment holds a platform key for that provider. `creds` is what
      came in with the platform key merged in under the provider's credential,
      so everything downstream — the broker split, the runtime's
      `default_env/2`, the redaction register — treats it as exactly what it
      is: a credential for that provider.
    * `{:error, :no_credential}` — neither. The caller keeps today's
      behaviour, which is to provision anyway and let the runtime report the
      provider's own auth failure on the transcript.

  **The tenant's credential always wins**, and there is no per-agent toggle:
  a tenant who has supplied a key is never quietly run on Fountain's, whatever
  their balance says. The tenant's other credentials survive the merge, so an
  agent with an `openai` model on an account that holds only an Anthropic key
  still exports that key for whatever else the sandbox does with it.

  `own_creds` is the decrypted map `decrypted_for_user/2` returns; over it
  this is a pure function, and testable without a tenant. The platform half
  is one read.

  `runtime` is the agent's (ADR 0047): for provider `openai` with no tenant
  credential, a `codex` agent takes the deployment's ChatGPT grant
  (`Fountain.PlatformChatGPT`) when it is active, under
  `:codex_chatgpt_access_token`, before the platform `OPENAI_API_KEY`. The
  grant is codex's own client speaking to its own backend; opencode against
  an `openai/` model keeps needing a key. The origin is `:platform` either
  way, so the ledger prices the turn and the daily ceiling counts it.

  `opts` carries `:secret_keys` (ADR 0053 decision 5), the environment
  variable names this conversation's environment and vault define. A tenant
  secret named after a static credential **wins in the sandbox** — `Egress`
  says so at the gate-3 split and `docs/concepts/secrets.md` publishes it —
  so a conversation that has one is running on the tenant's own credential
  and must not be selected `:platform`, priced against their credits or
  counted against the deployment's daily ceiling. Before this was read, a
  tenant using the documented override paid for platform inference they never
  used. Presence is all that is read: the value already reaches the sandbox
  through the secrets path, and putting it in `creds` as well would change
  which credential the runtime picks.

  A credential row is reported ahead of a secret when an account has both.
  Both are `origin: :own`, so nothing about billing turns on the order; the
  scope answers "why was this not platform-paid", and the row is the more
  specific answer because it is what Fountain itself exports.

  `opts` also carries `:brokered`, whether the conversation's credentials go
  through the egress broker (`Fountain.Broker.configured?/0`), default
  `true`. The grant is offered to brokered conversations only: unbrokered,
  the access token itself would land in the sandbox file, and the whole
  point of the grant is that a sandbox holds a placeholder. The platform
  API key has no such rule, as before. `:refresh` (default `true`) is
  whether a stale grant is refreshed on the way out; a caller that only
  asks whether a credential exists passes `false` and never waits on the
  auth server.
  """
  @spec select(String.t() | nil, %{atom() => String.t()}, String.t() | nil, keyword()) ::
          {:ok, Source.t(), %{atom() => String.t()}}
          | {:error, :no_credential}
  def select(model, own_creds, runtime \\ nil, opts \\ []) when is_map(own_creds) do
    provider = Managoat.Runtimes.Model.provider(model)
    accepted = credentials_for_provider(provider)

    cond do
      accepted == [] ->
        {:ok, Source.none(), own_creds}

      Enum.any?(accepted, &present?(own_creds, &1)) ->
        {:ok, Source.credential(), own_creds}

      shadowed?(accepted, Keyword.get(opts, :secret_keys, [])) ->
        {:ok, Source.tenant_secret(), own_creds}

      true ->
        case platform_credential(provider, runtime, Keyword.get(opts, :brokered, true), opts) do
          {:ok, credential, key} -> {:ok, Source.platform(), Map.put(own_creds, credential, key)}
          :none -> {:error, :no_credential}
        end
    end
  end

  # The subscription first for codex, then the platform key (ADR 0047
  # decision 6). A grant that is revoked, expired or fails to refresh is
  # `:none` here and the key takes over — at the next conversation, not
  # within a turn.
  defp platform_credential("openai", "codex", true, opts) do
    case Fountain.PlatformChatGPT.credential(refresh: Keyword.get(opts, :refresh, true)) do
      {:ok, token} -> {:ok, :codex_chatgpt_access_token, token}
      :none -> Fountain.PlatformInference.key_for("openai")
    end
  end

  defp platform_credential(provider, _runtime, _brokered?, _opts),
    do: Fountain.PlatformInference.key_for(provider)

  # Whether one of the credentials this provider accepts is defined as a
  # tenant secret for this conversation. Names only; the values stay where
  # they are.
  @spec shadowed?([atom()], Enumerable.t()) :: boolean()
  defp shadowed?(accepted, secret_keys) do
    names = MapSet.new(secret_keys, &to_string/1)
    Enum.any?(accepted, &MapSet.member?(names, Map.fetch!(@env_names, &1)))
  end

  defp present?(creds, credential) do
    case Map.get(creds, credential) do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  @doc """
  Returns a map `%{provider => boolean}` of which providers the user has set.
  Cheap — does not decrypt; just checks for non-nil ciphertext.
  """
  @spec status_for_user(binary()) :: %{atom() => boolean()}
  def status_for_user(user_id) when is_binary(user_id) do
    case get_for_user(user_id) do
      nil ->
        Map.new(@providers, &{&1, false})

      %Credential{} = cred ->
        Map.new(@providers, fn p ->
          ct = Map.fetch!(cred, ciphertext_field(p))
          {p, is_binary(ct) and byte_size(ct) > 0}
        end)
    end
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
