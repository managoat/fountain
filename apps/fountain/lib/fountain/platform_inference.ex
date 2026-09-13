defmodule Fountain.PlatformInference do
  @moduledoc """
  The deployment's own inference keys, and the ceiling on what they may spend
  in a day (#1388, ADR 0038 decision 3, amending ADR 0008).

  Fountain holds a set of inference keys and runs a tenant's agent on one when
  the tenant has none of their own. The tenant's credential always wins; a
  deployment that configures no platform key behaves exactly as it did before
  this module existed, which is what makes it opt-in for a self-hoster.

  ## What is here

    * `enabled?/0` and `key_for/1` — the keys. A key set from
      `/admin/inference` (`put_key/3`, one `platform_inference_keys` row per
      provider, encrypted under the master key) wins; otherwise
      `PLATFORM_ANTHROPIC_API_KEY`, `PLATFORM_OPENAI_API_KEY` and
      `PLATFORM_GEMINI_API_KEY`. Blank is off, per provider.
    * `put_key/3` and `clear_key/2` — the admin mutations, each leaving an
      `admin.platform_inference_key.*` row on the privilege trail. Clearing
      falls back to the variable rather than switching the provider off: the
      variable is the seed a deployment was configured with, and the row is
      the operator's later decision.
    * `status/0` — one entry per provider for the admin page: where the live
      key comes from, when and by whom it was set, and its last four
      characters.
    * `gate/2` — the door check: may this user's next conversation on this
      model start? `:ok` unless it would run on a platform key and the
      deployment has spent its day.
    * `check_ceiling/0` — the same ceiling without the "would it even use the
      platform key" question, for the per-turn backstop in
      `Conversations.TurnMachine.gate/2`, which already knows the answer.

  The *selection* rule lives in `Fountain.InferenceCredentials.select/2`, one
  function, because it is a statement about credentials rather than about
  money.

  ## The ceiling is a circuit breaker, not a quota

  `PLATFORM_INFERENCE_DAILY_CENTS` (default 5000, $50) bounds platform
  inference spend for the **whole deployment**, every tenant together, over a
  UTC day. It exists so one bad day cannot cost more than a number somebody
  wrote down. Hitting it is a 503, like `:fleet_full` — this is Fountain's
  limit, not the tenant's balance, and there is nothing they can buy to clear
  it (`FountainWeb.FallbackController`).

  Two properties worth knowing before trusting it:

    * **It is measured from the ledger**, so it lags `Workers.CreditPricer` by
      at most one tick. It bounds the day, not the minute.
    * **It needs `CREDITS_ENABLED=true`**, because that is what writes the
      ledger rows it reads. With credits off nothing is priced at all
      (ADR 0031), so nothing is counted and the ceiling never trips. A
      deployment that sets a platform key with credits off is paying its own
      inference bill knowingly and has no brake here.
  """

  require Logger

  alias Fountain.Audit
  alias Fountain.Crypto
  alias Fountain.PlatformInference.Key
  alias Fountain.Repo

  @providers %{
    "anthropic" => {:anthropic_api_key, :platform_anthropic_api_key},
    "openai" => {:openai_api_key, :platform_openai_api_key},
    "google" => {:gemini_api_key, :platform_gemini_api_key}
  }

  @env_vars %{
    "anthropic" => "PLATFORM_ANTHROPIC_API_KEY",
    "openai" => "PLATFORM_OPENAI_API_KEY",
    "google" => "PLATFORM_GEMINI_API_KEY"
  }

  # Long enough for any provider key seen so far, short enough that a pasted
  # certificate or a whole .env file is refused rather than stored.
  @max_key_bytes 1_024

  @doc "The providers a platform key can be held for, in `Managoat.Runtimes.Model` order."
  @spec providers() :: [String.t()]
  def providers,
    do: Enum.filter(Managoat.Runtimes.Model.providers(), &Map.has_key?(@providers, &1))

  @doc "The environment variable that seeds a provider's key."
  @spec env_var(String.t()) :: String.t() | nil
  def env_var(provider), do: Map.get(@env_vars, provider)

  @doc "Whether this deployment holds a platform key for any provider at all."
  @spec enabled?() :: boolean()
  def enabled?, do: configured_providers() != []

  @doc """
  The providers this deployment holds a key for, in `Managoat.Runtimes.Model`
  order. For the admin surfaces and the docs test; never a gate.
  """
  @spec configured_providers() :: [String.t()]
  def configured_providers do
    rows = stored_rows()

    Enum.filter(providers(), fn provider ->
      {_credential, config_key} = Map.fetch!(@providers, provider)
      resolve(provider, config_key, Map.get(rows, provider)) != :none
    end)
  end

  # Every stored row in one read, keyed by provider, for the callers that
  # ask about all providers at once.
  defp stored_rows(preload \\ []) do
    Key
    |> Repo.all()
    |> Repo.preload(preload)
    |> Map.new(&{&1.provider, &1})
  end

  @doc """
  The platform key for a provider: `{:ok, credential, key}` — the credential
  atom `Fountain.InferenceCredentials` uses for it, so the value drops into
  the same map a tenant's own key lives in — or `:none`.

  A row set from the admin page wins over the variable. A blank variable is
  `:none`, not an empty key: an unset variable and a variable set to `""` are
  the same statement, and the second is what a Helm chart with no value
  produces.

  One primary-key read per call. A stored row the master key no longer
  decrypts is treated as absent (and logged), so a rotated
  `MASTER_SECRETS_KEY` degrades to the variable rather than to a key that
  fails every request.
  """
  @spec key_for(String.t() | nil) :: {:ok, atom(), String.t()} | :none
  def key_for(provider) when is_binary(provider) do
    case Map.get(@providers, provider) do
      nil ->
        :none

      {credential, config_key} ->
        case resolve(provider, config_key, Repo.get(Key, provider)) do
          {:ok, key, _source} -> {:ok, credential, key}
          :none -> :none
        end
    end
  end

  def key_for(_provider), do: :none

  # Stored first, then the variable. `:undecryptable` falls through to the
  # variable on purpose — see key_for/1.
  defp resolve(provider, config_key, row) do
    case stored(provider, row) do
      {:ok, key} ->
        {:ok, key, :stored}

      _ ->
        case Application.get_env(:fountain, config_key) do
          key when is_binary(key) and key != "" -> {:ok, key, :environment}
          _ -> :none
        end
    end
  end

  defp stored(_provider, nil), do: :none

  defp stored(provider, %Key{ciphertext: ciphertext}) do
    case Crypto.decrypt_platform(ciphertext) do
      {:ok, key} when key != "" ->
        {:ok, key}

      _ ->
        Logger.warning(
          "platform inference: the stored #{provider} key does not decrypt under " <>
            "MASTER_SECRETS_KEY; falling back to #{env_var(provider)}. Set it again at /admin/inference."
        )

        :undecryptable
    end
  end

  @doc """
  Set a provider's platform key from the admin panel. The value is trimmed,
  refused when empty (clear it with `clear_key/2` instead), when it has
  whitespace inside it, or when it is longer than a key could be.

  `opts` carries `:actor_user_id`, the operator, for the row and for the
  `admin.platform_inference_key.set` event. The trail records the provider
  and what the row replaced (`"stored"`, `"environment"` or `"none"`), never
  any part of the value.
  """
  @spec put_key(String.t(), String.t(), keyword()) :: {:ok, Key.t()} | {:error, :invalid_key}
  def put_key(provider, value, opts \\ []) when is_binary(provider) and is_binary(value) do
    value = String.trim(value)

    with :ok <- validate_key(value),
         {_, config_key} <- Map.get(@providers, provider, :none) do
      row = Repo.get(Key, provider)
      previous = source_name(resolve(provider, config_key, row))
      actor_user_id = Keyword.get(opts, :actor_user_id)

      attrs = %{
        provider: provider,
        ciphertext: Crypto.encrypt_platform(value),
        updated_by_user_id: actor_user_id
      }

      result =
        (row || %Key{})
        |> Key.changeset(attrs, providers())
        |> Repo.insert_or_update()

      case result do
        {:ok, _} = ok ->
          Audit.record_admin(%{
            actor_user_id: actor_user_id,
            event_type: "admin.platform_inference_key.set",
            metadata: %{"provider" => provider, "replaced" => previous}
          })

          ok

        {:error, _changeset} ->
          {:error, :invalid_key}
      end
    else
      _ -> {:error, :invalid_key}
    end
  end

  @doc """
  Remove a provider's stored key. The provider falls back to its variable,
  or to off when that is blank too. `:ok` either way; the
  `admin.platform_inference_key.cleared` event is recorded only when a row
  was actually there, since a trail that logs attempts as changes is worse
  than no trail (ADR 0013).
  """
  @spec clear_key(String.t(), keyword()) :: :ok
  def clear_key(provider, opts \\ []) when is_binary(provider) do
    case Repo.get(Key, provider) do
      nil ->
        :ok

      %Key{} = key ->
        Repo.delete!(key)

        Audit.record_admin(%{
          actor_user_id: Keyword.get(opts, :actor_user_id),
          event_type: "admin.platform_inference_key.cleared",
          metadata: %{"provider" => provider}
        })

        :ok
    end
  end

  @doc """
  One entry per provider for `/admin/inference`: `:source` is `:stored`,
  `:environment`, `:undecryptable` or `:none`; `:hint` is the live key's last
  four characters (enough to tell two keys apart, not enough to use one);
  `:updated_at` and `:updated_by` describe the stored row when there is one;
  `:env_var` names the variable that seeds it.
  """
  @spec status() :: [map()]
  def status do
    rows = stored_rows([:updated_by])

    for provider <- providers() do
      {_credential, config_key} = Map.fetch!(@providers, provider)
      row = Map.get(rows, provider)

      {source, hint} =
        case stored(provider, row) do
          {:ok, key} ->
            {:stored, hint(key)}

          :undecryptable ->
            {:undecryptable, nil}

          :none ->
            case resolve(provider, config_key, nil) do
              {:ok, key, :environment} -> {:environment, hint(key)}
              :none -> {:none, nil}
            end
        end

      %{
        provider: provider,
        env_var: env_var(provider),
        source: source,
        hint: hint,
        updated_at: row && row.updated_at,
        updated_by: row && row.updated_by && row.updated_by.email
      }
    end
  end

  defp hint(key) when byte_size(key) > 4, do: String.slice(key, -4, 4)
  defp hint(_key), do: nil

  defp source_name({:ok, _key, source}), do: Atom.to_string(source)
  defp source_name(:none), do: "none"

  defp validate_key(""), do: {:error, :invalid_key}

  defp validate_key(value) when byte_size(value) > @max_key_bytes, do: {:error, :invalid_key}

  defp validate_key(value) do
    if Regex.match?(~r/[[:space:][:cntrl:]]/u, value), do: {:error, :invalid_key}, else: :ok
  end

  @doc """
  The daily ceiling in cents (`PLATFORM_INFERENCE_DAILY_CENTS`, default 5000).
  """
  @spec daily_ceiling_cents() :: non_neg_integer()
  def daily_ceiling_cents do
    case Application.get_env(:fountain, :platform_inference_daily_cents) do
      cents when is_integer(cents) and cents >= 0 -> cents
      _ -> 5_000
    end
  end

  @doc """
  The door check, at every place a conversation begins: `:ok`, or
  `{:error, :platform_inference_unavailable}`.

  Three questions, cheapest first, so a deployment with no platform key
  costs one primary-key read and nothing else:

    1. does this deployment hold a key for the model's provider?
    2. would this user actually take it — that is, do they have none of their
       own for that provider?
    3. has the deployment spent its day?

  Only a "yes" to all three refuses.

  `runtime` is the agent's: a codex agent on an `openai` model may run on the
  deployment's ChatGPT grant instead of a key (ADR 0047), which the ceiling
  counts the same way.

  `opts` names this launch's `:environment_id` and `:vault_id` so question 2
  asks what the provision will answer. A secret of theirs named after a
  credential serves the conversation instead of the platform key (ADR 0053
  decision 5), so without them this door refused a tenant running on their
  own key once the deployment had spent its day. The extra read happens only
  when the first question already said yes and the account holds no row, so
  a deployment with no platform key still costs nothing here.
  """
  @spec gate(binary(), String.t() | nil, String.t() | nil, keyword()) ::
          :ok | {:error, :platform_inference_unavailable}
  def gate(user_id, model, runtime \\ nil, opts \\ []) when is_binary(user_id) do
    provider = Managoat.Runtimes.Model.provider(model)

    if serves?(provider, runtime, Fountain.Broker.configured?()) and
         not Fountain.InferenceCredentials.has_own?(user_id, model, opts) do
      check_ceiling()
    else
      :ok
    end
  end

  @doc """
  Whether this deployment would run a tenant with no credential of their own
  on something of Fountain's for this provider and runtime: a platform key,
  or, for a brokered codex conversation, the ChatGPT grant. The same three
  questions `InferenceCredentials.select/4` asks, so the gate never refuses
  for a credential the selection would not hand out.
  """
  @spec serves?(String.t() | nil, String.t() | nil, boolean()) :: boolean()
  def serves?(provider, runtime, brokered?) do
    key_for(provider) != :none or
      (brokered? and provider == "openai" and runtime == "codex" and
         Fountain.PlatformChatGPT.active?())
  end

  @doc """
  The ceiling on its own, for a caller that already knows the turn runs on a
  platform key.

  `:ok` when credits are off (nothing is counted), when the ceiling is zero
  (which reads as "unbounded" the way `SANDBOX_CAP_CEILING` does not — see
  below), or when the day's spend is under it.
  """
  @spec check_ceiling() :: :ok | {:error, :platform_inference_unavailable}
  def check_ceiling do
    ceiling = daily_ceiling_cents()

    # Zero is "no platform inference today", not "unbounded": the variable
    # exists to bound spend, so the degenerate value has to bound it hardest.
    # An operator who wants the feature off unsets the keys.
    spent = Fountain.Billing.platform_inference_spend_today()

    cond do
      is_nil(spent) ->
        :ok

      spent < ceiling ->
        :ok

      true ->
        Logger.warning(
          "platform inference: daily ceiling reached (#{spent} of #{ceiling} cents); " <>
            "refusing conversations that would run on a platform key until UTC midnight"
        )

        {:error, :platform_inference_unavailable}
    end
  end
end
