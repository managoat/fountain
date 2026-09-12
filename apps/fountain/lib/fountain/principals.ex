defmodule Fountain.Principals do
  @moduledoc """
  Claimable principals (ADR 0044, #1551).

  A **principal** is a `users` row with `principal: true`: an identity-less
  tenant that a trusted application opens for a visitor who has no Fountain
  account yet. It is a first-class tenant from its first request — its own
  DEK, its own agents, environments, vaults and conversations, its own slice
  of the credit ledger, its own audit trail — and its id is the id already
  baked into every sandbox name it creates.

  **Claiming attaches an owner. It never moves a resource.** A
  `principal_owners` row records that a registered account is now behind the
  principal; nothing about the machine is touched, which is the whole point.
  The sandbox, the disk, the agent, the conversations and every id survive
  the claim unchanged, because a transfer that re-parented them would change
  the `user_id` component of the sprite name and hand the visitor a different
  machine.

  ## What is temporary

  `claimable_users` holds everything that is: the application that opened the
  principal, when it expires, what it may spend, the hashed one-time claim
  token, and the idempotency keys. The principal's `users` row holds none of
  it — after a claim there is nothing provisional left to describe.

  ## Limits are the mechanisms that already exist

    * `max_live_sandboxes` is written to `users.sandbox_limit_override`, so
      `Fountain.Quotas` needs no knowledge of principals: the override branch
      answers before the balance rule is ever consulted. Because it answers
      first, it is clamped at creation to the application's own effective cap
      under the deployment ceiling, so a principal can never out-provision the
      account funding it — and never below one, because a zero written there is
      a gate that funding cannot reopen (#1687).
    * `max_cost_usd` is a credit grant moved from the application's balance
      into the principal's, so budget exhaustion is `Billing.check_spend/1`
      refusing at every door that spends (ADR 0031). With credits off nothing
      is priced anywhere, so a principal is bounded by its expiry and its
      sandbox cap alone.

  ## Two-stage teardown

  Expiring or releasing a principal revokes its credentials, destroys its
  sandboxes and refunds the unspent grant — but keeps the rows, so the
  application can still reconcile a lost response against
  `GET /api/claimable-users/:id`. `Fountain.Workers.ClaimablePrincipalSweep`
  deletes the principal itself a retention window later.

  ## Configuration

      config :fountain, Fountain.Principals,
        default_ttl_seconds: 86_400,
        max_ttl_seconds: 604_800,
        max_grant_cents: 500,
        max_outstanding_per_application: 500,
        max_created_per_hour: 500,
        purge_after_days: 7
  """

  import Ecto.Query

  alias Fountain.Accounts
  alias Fountain.Accounts.{ApiKey, Deletion, User}
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Audit
  alias Fountain.Principals.{ClaimableUser, Owner}
  alias Fountain.Repo

  require Logger

  @token_bytes 32

  # ── settings ────────────────────────────────────────────────────────────────

  @doc "The TTL, budget and abuse ceilings in force."
  @spec settings() :: %{
          default_ttl_seconds: pos_integer(),
          max_ttl_seconds: pos_integer(),
          max_grant_cents: non_neg_integer(),
          max_outstanding_per_application: non_neg_integer(),
          max_created_per_hour: non_neg_integer(),
          purge_after_days: non_neg_integer()
        }
  def settings do
    cfg = Application.get_env(:fountain, __MODULE__, [])

    %{
      default_ttl_seconds: Keyword.get(cfg, :default_ttl_seconds, 86_400),
      max_ttl_seconds: Keyword.get(cfg, :max_ttl_seconds, 604_800),
      max_grant_cents: Keyword.get(cfg, :max_grant_cents, 500),
      max_outstanding_per_application: Keyword.get(cfg, :max_outstanding_per_application, 500),
      max_created_per_hour: Keyword.get(cfg, :max_created_per_hour, 500),
      purge_after_days: Keyword.get(cfg, :purge_after_days, 7)
    }
  end

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc """
  The grant behind a principal id, or nil.

  Unscoped, and named for it: the callers are this module, the credit gate and
  the sweep, none of which has a tenant to scope by. A request-path read goes
  through `get_claimable_for/2`.
  """
  @spec _unsafe_get_by_principal(binary()) :: ClaimableUser.t() | nil
  def _unsafe_get_by_principal(user_id) when is_binary(user_id) do
    Repo.get_by(ClaimableUser, user_id: user_id)
  end

  @doc """
  The grant with id `id`, if `viewer_id` is allowed to see it.

  Two accounts are: the application that opened it, and the account that
  claimed it. Anyone else reads `nil` rather than a 403, so a grant id cannot
  be probed for existence.
  """
  @spec get_claimable_for(binary(), binary()) :: ClaimableUser.t() | nil
  def get_claimable_for(id, viewer_id) when is_binary(id) and is_binary(viewer_id) do
    ClaimableUser
    |> where([c], c.id == ^id)
    |> where([c], c.application_user_id == ^viewer_id or c.claimed_by_user_id == ^viewer_id)
    |> Repo.one()
  end

  @doc "The account that owns `principal_user_id`, or nil when nobody does."
  @spec owner_id(binary()) :: binary() | nil
  def owner_id(principal_user_id) when is_binary(principal_user_id) do
    from(o in Owner,
      where: o.principal_user_id == ^principal_user_id,
      select: o.owner_user_id
    )
    |> Repo.one()
  end

  @doc """
  Write or clear one provider credential on a principal, as the account
  behind it (ADR 0053 decision 7).

  A principal is a first-class tenant with its own credential rows, and a
  `principal`-scoped key cannot write account state -- so without this an
  application could open a principal for a customer and then have no way to
  put that customer's inference key on it. That gap is what kept a business
  managing several end customers on one shared account instead of one
  principal each.

  `viewer_id` is authorised exactly as `get_claimable_for/2` authorises a
  read: the application that opened the principal, or the account that
  claimed it. Anyone else gets `:not_found`, so a grant id cannot be probed.
  The principal's own credential gains nothing from this route.

  The value is encrypted under the **principal's** DEK and lands in the
  principal's default credential set, because it is the principal's
  credential; the owner is only who asked. The trail is the principal's too,
  with the acting account named in the metadata.
  """
  @spec put_inference_credential(binary(), binary(), atom(), String.t() | nil, keyword()) ::
          {:ok, Fountain.InferenceCredentials.Credential.t()}
          | {:error, :not_found | :tenant_key_unavailable | Ecto.Changeset.t()}
  def put_inference_credential(id, viewer_id, provider, value, opts \\ [])
      when is_binary(id) and is_binary(viewer_id) do
    with %ClaimableUser{user_id: principal_id} <- get_claimable_for(id, viewer_id) || :none,
         {:ok, dek} <- load_principal_key(principal_id) do
      Fountain.InferenceCredentials.put_credential(
        principal_id,
        dek,
        provider,
        value,
        Keyword.update(
          opts,
          :metadata,
          %{"by_account" => viewer_id},
          &Map.put(&1, "by_account", viewer_id)
        )
      )
    else
      :none -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_principal_key(principal_id) do
    case Fountain.Crypto.load_tenant_key(principal_id) do
      {:ok, dek} -> {:ok, dek}
      {:error, _reason} -> {:error, :tenant_key_unavailable}
    end
  end

  @doc "Every principal `owner_user_id` holds, oldest first."
  @spec list_owned(binary()) :: [binary()]
  def list_owned(owner_user_id) when is_binary(owner_user_id) do
    from(o in Owner,
      where: o.owner_user_id == ^owner_user_id,
      order_by: [asc: o.inserted_at],
      select: o.principal_user_id
    )
    |> Repo.all()
  end

  @doc """
  Whose ledger funds work done as `subject` (ADR 0044 decision 4).

  An ordinary account is its own subject and costs nothing to resolve — the
  `principal` flag on a loaded `%User{}` answers without a query. A claimed
  principal resolves to its owner, so usage after a claim lands on the
  registered account; an unclaimed one resolves to itself, where the
  application's introductory grant is.

  Money follows the owner. Usage events do not: `Billing.record_usage/5`
  records what the *principal* did, which is what an application reconciling
  a visitor's session needs to read.
  """
  @spec billing_subject_id(User.t() | binary()) :: binary()
  def billing_subject_id(%User{principal: false, id: id}), do: id
  def billing_subject_id(%User{id: id}), do: billing_subject_id(id)

  def billing_subject_id(user_id) when is_binary(user_id) do
    owner_id(user_id) || user_id
  end

  # ── create ──────────────────────────────────────────────────────────────────

  @doc """
  Open a claimable principal on behalf of `application`.

  `params` is the decoded request body — `"application_id"`, `"expires_in"`,
  `"limits"` (`"max_live_sandboxes"`, `"max_cost_usd"`) and `"metadata"` — and
  `opts` carries `:idempotency_key` plus the usual audit attribution.

  Returns `{:ok, %{claimable: c, api_key: raw, claim_token: token}}`. Both
  secrets are returned once and stored only as hashes.

  Replaying `:idempotency_key` returns the **same** principal with a **fresh**
  API key and claim token. Reissuing is the only way a replay can be useful:
  the first response's secrets were never stored, so an application that lost
  that response has nothing to operate the principal with. A replay therefore
  invalidates the previous pair, which is safe precisely because a replay
  means the first pair never arrived.

  A replay against a grant that is no longer open is `{:error, :already_claimed}`,
  `{:error, :expired}` or `{:error, :released}`, and mints nothing. Reissuing
  there would be the reverse of the claim: an application handing itself a
  working credential for a machine that now belongs to somebody, by replaying
  a key it kept.
  """
  @spec create_claimable(User.t(), map(), keyword()) ::
          {:ok, %{claimable: ClaimableUser.t(), api_key: String.t(), claim_token: String.t()}}
          | {:error, term()}
  def create_claimable(%User{} = application, params, opts \\ []) do
    with {:ok, attrs} <- cast_create(application, params),
         {:ok, claimable} <- upsert_claimable(application, attrs, opts) do
      issue_credentials(claimable, opts)
    end
  end

  # A third ceiling in the spirit of the two in `check_application_allowed/2`,
  # bounding a leaked application key: `max_live_sandboxes` lands on
  # `users.sandbox_limit_override`, which `Quotas.resolve_limit/3` answers with
  # *before* the balance rule and the cap ceiling are ever consulted. Unclamped,
  # a full-scope key could mint principals on a cent each that out-provision the
  # account funding them, up to `SANDBOX_FLEET_CEILING` (#1687).
  defp cast_create(%User{} = application, params) do
    %{max_ttl_seconds: max_ttl, default_ttl_seconds: default_ttl, max_grant_cents: max_grant} =
      settings()

    application_id = params |> Map.get("application_id") |> to_string() |> String.trim()
    limits = Map.get(params, "limits") || %{}

    ttl =
      params
      |> Map.get("expires_in", default_ttl)
      |> as_integer(default_ttl)
      |> clamp(1, max_ttl)

    cond do
      application_id == "" ->
        {:error, {:invalid, "application_id is required"}}

      String.length(application_id) > 100 ->
        {:error, {:invalid, "application_id is at most 100 characters"}}

      not is_map(Map.get(params, "metadata", %{})) ->
        {:error, {:invalid, "metadata must be an object"}}

      true ->
        {:ok,
         %{
           application_id: application_id,
           expires_at: DateTime.utc_now() |> DateTime.add(ttl, :second) |> truncate(),
           grant_cents:
             limits |> Map.get("max_cost_usd") |> usd_to_cents() |> clamp(0, max_grant),
           max_live_sandboxes:
             limits
             |> Map.get("max_live_sandboxes")
             |> as_integer(1)
             |> clamp(0, application_cap(application)),
           metadata: Map.get(params, "metadata", %{})
         }}
    end
  end

  # What the application may hand a principal: its own effective cap, itself
  # held to the deployment ceiling, and never below one.
  #
  # Read by **id**, for the reason `check_application_allowed/2` gives about
  # the balance: the `%User{}` the caller loaded carries a cached cap input
  # that may predate its own opening credit.
  #
  # `min(cap_ceiling)` because `resolve_limit/3` returns an application's *own*
  # `sandbox_limit_override` unclamped — an admin lever of 50 under a ceiling
  # of 20 would otherwise be inherited by every principal it opens.
  #
  # `max(1)` because an application with an empty balance has an effective cap
  # of zero, and a zero written here is durable: `resolve_limit/3` answers with
  # the override before the balance rule, no claim clears it, and only an
  # operator can undo it. That is the 0/0 quota `Fountain.Quotas` says never to
  # show, on a principal that funding cannot reopen. The gate is the balance
  # (ADR 0031) — `check_spend/1` refuses a principal with no credit at every
  # door that spends, and stops refusing the moment it has some — so a cap of
  # one on a broke application's principal costs nothing and heals itself. An
  # *explicit* zero is still honoured: that is an application asking for a
  # principal that runs nothing, which the schema has always allowed.
  defp application_cap(%User{} = application) do
    %{cap_ceiling: ceiling} = Fountain.Quotas.settings()

    application.id
    |> Fountain.Quotas.sandbox_limit()
    |> min(ceiling)
    |> max(1)
  end

  # The application funds its principals out of its own balance, so it must
  # actually hold the grant it is about to make. Checked by **id**, never by the
  # `%User{}` the caller loaded: `check_balance/2` honours a struct's cached
  # balance, and a struct read before its own opening credit landed would report
  # money the account has and money it does not with equal confidence.
  #
  # The two ceilings on top of it bound a leaked application key. The balance is
  # the backstop; neither is a rate limit for a well-behaved caller.
  defp check_application_allowed(%User{} = application, grant_cents) do
    %{
      max_outstanding_per_application: max_outstanding,
      max_created_per_hour: max_per_hour
    } = settings()

    cond do
      # Unreachable through the API — every route here is full-scope and a
      # principal only ever holds a `principal`-scoped key — and asserted
      # anyway, because "a principal cannot open a principal" is a property of
      # the model, not of one router line.
      application.principal ->
        {:error, :ineligible}

      grant_cents > 0 and
          Fountain.Credits.check_balance(application.id, min: grant_cents) != :ok ->
        {:error, :insufficient_credits}

      outstanding_count(application.id) >= max_outstanding ->
        {:error, :too_many_outstanding_principals}

      created_since(application.id, DateTime.add(DateTime.utc_now(), -3600, :second)) >=
          max_per_hour ->
        {:error, :principal_rate_limited}

      true ->
        :ok
    end
  end

  defp outstanding_count(application_user_id) do
    ClaimableUser
    |> where([c], c.application_user_id == ^application_user_id and c.status == "unclaimed")
    |> select([c], count(c.id))
    |> Repo.one()
  end

  defp created_since(application_user_id, since) do
    ClaimableUser
    |> where([c], c.application_user_id == ^application_user_id and c.inserted_at >= ^since)
    |> select([c], count(c.id))
    |> Repo.one()
  end

  # The idempotency replay is answered before the insert rather than by
  # catching its unique-constraint error, because the two outcomes are
  # different work: a replay reissues credentials against an existing
  # principal, and only a genuinely new key builds one.
  defp upsert_claimable(%User{} = application, attrs, opts) do
    case existing_for_key(application.id, Keyword.get(opts, :idempotency_key)) do
      %ClaimableUser{} = c ->
        still_open(c)

      nil ->
        with :ok <- check_application_allowed(application, attrs.grant_cents) do
          insert_claimable(application, attrs, opts)
        end
    end
  end

  # A grant that is closed, or claimed, is not a thing to hand credentials for.
  # `usable?/2` reads the deadline rather than the status, so a replay in the
  # window between an expiry and the sweep that records it is refused too.
  defp still_open(%ClaimableUser{status: "claimed"}), do: {:error, :already_claimed}
  defp still_open(%ClaimableUser{status: "released"}), do: {:error, :released}
  defp still_open(%ClaimableUser{status: "expired"}), do: {:error, :expired}

  defp still_open(%ClaimableUser{} = c) do
    if ClaimableUser.usable?(c), do: {:ok, c}, else: {:error, :expired}
  end

  defp existing_for_key(_application_user_id, nil), do: nil

  defp existing_for_key(application_user_id, key) do
    Repo.get_by(ClaimableUser,
      application_user_id: application_user_id,
      create_idempotency_key: key
    )
  end

  defp insert_claimable(%User{} = application, attrs, opts) do
    result =
      Repo.transaction(fn ->
        with {:ok, principal} <-
               Accounts.create_principal_user(sandbox_limit_override: attrs.max_live_sandboxes),
             {:ok, claimable} <- insert_grant_row(principal, application, attrs, opts) do
          claimable
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, claimable} <- result do
      # Outside the transaction, both of them: a ledger post takes its own
      # row lock and an audit insert that fails inside a transaction takes the
      # transaction with it (ADR 0013).
      fund(claimable, application, opts)

      record(claimable, "claimable_user.created", opts, %{
        "application_id" => claimable.application_id,
        "principal_id" => claimable.user_id,
        "expires_at" => DateTime.to_iso8601(claimable.expires_at),
        "grant_cents" => claimable.grant_cents,
        "max_live_sandboxes" => claimable.max_live_sandboxes
      })

      {:ok, claimable}
    end
  end

  defp insert_grant_row(%User{} = principal, %User{} = application, attrs, opts) do
    %ClaimableUser{}
    |> ClaimableUser.changeset(%{
      user_id: principal.id,
      application_user_id: application.id,
      application_id: attrs.application_id,
      expires_at: attrs.expires_at,
      grant_cents: attrs.grant_cents,
      max_live_sandboxes: attrs.max_live_sandboxes,
      create_idempotency_key: Keyword.get(opts, :idempotency_key),
      metadata: attrs.metadata
    })
    |> Repo.insert()
  end

  # The introductory grant (ADR 0044 decision 3): the application pays for it
  # out of its own balance, so the money exists before the principal can spend
  # it. Best-effort by rescuing — with credits off both posts are no-ops, and a
  # ledger hiccup must not cost the application a principal it can still
  # operate (an unfunded one simply fails the gate at its first turn).
  defp fund(%ClaimableUser{grant_cents: cents}, _application, _opts) when cents <= 0, do: :ok

  defp fund(%ClaimableUser{} = claimable, %User{} = application, opts) do
    if Fountain.Credits.enabled?() do
      move_grant(claimable, application, Keyword.get(opts, :actor, "api"))
    end

    :ok
  rescue
    e ->
      Logger.warning("funding principal #{claimable.user_id} failed: #{inspect(e)}")
      :ok
  end

  # Two rows under two keys. The ledger's idempotency index is global, so the
  # debit and the credit cannot share one — posting the second under the
  # first's key would read as a duplicate and the principal would arrive
  # unfunded with the application already charged.
  defp move_grant(%ClaimableUser{} = claimable, %User{} = application, actor) do
    Fountain.Credits.debit(application.id, claimable.grant_cents, "burn_grant",
      idempotency_key: "principal_grant_paid:#{claimable.id}",
      resource_type: "claimable_user",
      resource_id: claimable.id,
      actor: actor
    )

    Fountain.Credits.grant(claimable.user_id, claimable.grant_cents, "grant_application",
      idempotency_key: grant_key(claimable),
      expires_at: claimable.expires_at,
      resource_type: "claimable_user",
      resource_id: claimable.id,
      actor: actor
    )
  end

  # Both secrets at once, and both replaceable: the API key is minted fresh and
  # the claim token's hash is rewritten, so a replayed create hands back a
  # usable pair rather than two values the caller can do nothing with.
  defp issue_credentials(%ClaimableUser{} = claimable, opts) do
    # Claim and expiry revoke keys under this same lock. The earlier replay
    # lookup is only a snapshot: recheck after the lock, and hold it through
    # both credential writes so a claim cannot miss a newly minted key.
    result =
      Repo.transaction(fn ->
        token = new_token()

        with %ClaimableUser{} = current <- lock_claimable(claimable.id),
             {:ok, current} <- still_open(current),
             {changeset, raw} =
               Accounts.build_api_key(
                 current.user_id,
                 key_name(current),
                 principal_key_opts(current, opts)
               ),
             {:ok, key} <- Repo.insert(changeset),
             {:ok, current} <-
               current
               |> Ecto.Changeset.change(claim_token_hash: hash_token(token))
               |> Repo.update() do
          {%{claimable: current, api_key: raw, claim_token: token}, key}
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {credentials, key}} ->
        Accounts.record_api_key_created(key, principal_key_opts(claimable, opts))
        {:ok, credentials}

      {:error, _} = error ->
        error
    end
  end

  # The anonymous credential expires with the grant, so a leaked one dies on
  # the same schedule as the machine it reaches. The claimed one must not:
  # after a claim the grant's deadline describes nothing — the principal is an
  # ordinary tenant of the account that owns it — and a key that expired at it
  # would take a live machine away from its new owner, usually within hours.
  defp mint_principal_key(%ClaimableUser{} = claimable, opts) do
    Accounts.create_api_key(
      claimable.user_id,
      key_name(claimable),
      principal_key_opts(claimable, opts)
    )
  end

  defp principal_key_opts(claimable, opts) do
    [
      scopes: ["principal"],
      expires_at: if(claimable.status == "claimed", do: nil, else: claimable.expires_at),
      actor: Keyword.get(opts, :actor, "api"),
      request_ip: Keyword.get(opts, :request_ip)
    ]
  end

  defp key_name(%ClaimableUser{status: "claimed", application_id: app}), do: "principal:#{app}"
  defp key_name(%ClaimableUser{application_id: app}), do: "claimable:#{app}"

  # ── claim ───────────────────────────────────────────────────────────────────

  @doc """
  Claim `id` for `claimer`, presenting the one-time `claim_token`.

  Attaches `claimer` as the principal's owner and returns a fresh
  `principal`-scoped credential for it. Nothing about the principal's
  resources is touched.

  `opts` carries `:idempotency_key` plus audit attribution. Replaying a
  successful claim with the same key **and** the same claimer returns the same
  outcome with a fresh credential; any other repeat is
  `{:error, :already_claimed}`.

  Errors: `:not_found`, `:invalid_claim_token`, `:already_claimed`,
  `:expired`, `:released`, and `:ineligible` when the claiming account cannot
  fund future work. `:ineligible` is checked before anything is written, so a
  refused claim leaves the principal exactly as it was.
  """
  @spec claim(binary(), String.t(), User.t(), keyword()) ::
          {:ok, %{claimable: ClaimableUser.t(), api_key: String.t()}} | {:error, term()}
  def claim(id, claim_token, %User{} = claimer, opts \\ []) when is_binary(id) do
    with :ok <- check_claimer_eligible(claimer),
         {:ok, {claimable, replay?}} <- attach_owner(id, claim_token, claimer, opts),
         {:ok, {_key, raw}} <- mint_principal_key(claimable, opts) do
      if not replay? do
        settle_grant(claimable, opts)
        record_claim(claimable, claimer, opts)
      end

      {:ok, %{claimable: claimable, api_key: raw}}
    end
  end

  # An account that cannot fund work would claim a machine it could not then
  # run, and the claim is what moves future spend onto its ledger.
  defp check_claimer_eligible(%User{} = claimer) do
    cond do
      claimer.principal -> {:error, :ineligible}
      is_nil(claimer.email_verified_at) -> {:error, :ineligible}
      not is_nil(claimer.suspended_at) -> {:error, :ineligible}
      # By id, for the reason `check_application_allowed/2` gives.
      Fountain.Billing.check_spend(claimer.id) != :ok -> {:error, :ineligible}
      true -> :ok
    end
  end

  # One transaction, one row lock. The expirer takes the same lock, so a claim
  # that beats it by a millisecond is a claim, and two competing claims are one
  # success and one `:already_claimed`.
  defp attach_owner(id, claim_token, %User{} = claimer, opts) do
    Repo.transaction(fn ->
      case lock_claimable(id) do
        nil -> Repo.rollback(:not_found)
        %ClaimableUser{} = c -> decide_claim(c, claim_token, claimer, opts)
      end
    end)
  end

  defp lock_claimable(id) do
    ClaimableUser |> where([c], c.id == ^id) |> lock("FOR UPDATE") |> Repo.one()
  end

  defp decide_claim(%ClaimableUser{status: "claimed"} = c, _token, claimer, opts) do
    key = Keyword.get(opts, :idempotency_key)

    if c.claimed_by_user_id == claimer.id and not is_nil(key) and c.claim_idempotency_key == key do
      {c, true}
    else
      Repo.rollback(:already_claimed)
    end
  end

  defp decide_claim(%ClaimableUser{status: "released"}, _token, _claimer, _opts) do
    Repo.rollback(:released)
  end

  defp decide_claim(%ClaimableUser{status: "expired"}, _token, _claimer, _opts) do
    Repo.rollback(:expired)
  end

  defp decide_claim(%ClaimableUser{} = c, token, %User{} = claimer, opts) do
    cond do
      not ClaimableUser.usable?(c) -> Repo.rollback(:expired)
      not valid_token?(c, token) -> Repo.rollback(:invalid_claim_token)
      true -> {write_claim(c, claimer, opts), false}
    end
  end

  defp write_claim(%ClaimableUser{} = c, %User{} = claimer, opts) do
    {:ok, _owner} =
      %Owner{}
      |> Owner.changeset(%{owner_user_id: claimer.id, principal_user_id: c.user_id})
      |> Repo.insert()

    # Every credential the application held stops working here, atomically with
    # the claim: an anonymous key that outlived the claim would be standing
    # access to a machine that now belongs to somebody.
    revoke_keys(c.user_id)

    {:ok, claimed} =
      c
      |> Ecto.Changeset.change(
        status: "claimed",
        claimed_at: DateTime.utc_now() |> truncate(),
        claimed_by_user_id: claimer.id,
        claim_idempotency_key: Keyword.get(opts, :idempotency_key),
        claim_token_hash: nil
      )
      |> Repo.update()

    claimed
  end

  defp record_claim(%ClaimableUser{} = claimable, %User{} = claimer, opts) do
    record(claimable, "claimable_user.claimed", opts, %{
      "application_id" => claimable.application_id,
      "principal_id" => claimable.user_id,
      "claimed_by_user_id" => claimer.id
    })
  end

  # ── release, expiry and the budget note ─────────────────────────────────────

  @doc """
  Abandon a grant: revoke its credentials, destroy its sandboxes, refund what
  the application's introductory grant still holds, and mark it `released`.

  The rows stay, so `GET /api/claimable-users/:id` still answers; the sweep
  deletes the principal a retention window later. A claimed principal is not
  the application's to release, and reads as `{:error, :already_claimed}`.
  """
  @spec release(ClaimableUser.t(), keyword()) :: {:ok, ClaimableUser.t()} | {:error, term()}
  def release(claimable, opts \\ [])

  def release(%ClaimableUser{status: "claimed"}, _opts), do: {:error, :already_claimed}

  def release(%ClaimableUser{} = claimable, opts) do
    close(claimable, "released", :released_at, "claimable_user.released", opts)
  end

  @doc """
  Close every unclaimed grant whose date has passed, longest overdue first.

  Returns the number expired. Bounded per run, so a backlog drains over
  several sweeps in the order the grants came due rather than in one giant
  pass. Takes the same row lock the claim does, so a claim landing in the same
  instant wins or loses cleanly rather than half-happening.
  """
  @spec expire_due(keyword()) :: non_neg_integer()
  def expire_due(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    ClaimableUser
    |> where([c], c.status == "unclaimed" and c.expires_at <= ^now)
    |> order_by([c], asc: c.expires_at)
    |> limit(200)
    |> Repo.all()
    |> Enum.count(fn c ->
      match?({:ok, _}, close(c, "expired", :expired_at, "claimable_user.expired", opts))
    end)
  end

  # Release and expiry are the same teardown with a different word on it, so
  # they are one function: whichever closes the grant revokes the credentials,
  # stops the compute and hands the unspent money back.
  defp close(%ClaimableUser{} = claimable, status, stamp, action, opts) do
    result =
      Repo.transaction(fn ->
        case lock_claimable(claimable.id) do
          # Revoked in the same transaction that closes the grant. There is no
          # retry for the steps below, so anything that must not survive a
          # crash between them belongs on this side of the commit; a live
          # credential on a closed principal is the one that must not.
          %ClaimableUser{status: "unclaimed"} = c ->
            revoke_keys(c.user_id)
            mark_closed(c, status, stamp)

          %ClaimableUser{} ->
            Repo.rollback(:not_open)

          nil ->
            Repo.rollback(:not_found)
        end
      end)

    with {:ok, closed} <- result do
      stop_compute(closed.user_id)
      settle_grant(closed, opts)

      record(closed, action, opts, %{
        "application_id" => closed.application_id,
        "principal_id" => closed.user_id
      })

      {:ok, closed}
    end
  end

  defp mark_closed(%ClaimableUser{} = c, status, stamp) do
    changes = %{:status => status, stamp => DateTime.utc_now() |> truncate()}

    {:ok, closed} = c |> Ecto.Changeset.change(changes) |> Repo.update()
    closed
  end

  # Settle the introductory grant: take back what its lot still holds and
  # return that to the application.
  #
  # Both halves, always. Crediting the application without expiring the
  # principal's lot would mint money — the same cents would sit in two
  # balances — and expiring without crediting would burn the application's.
  # The lot rather than the balance, so work the principal already did stays
  # paid for, and `expire_lot/2` reads the remaining amount under the same row
  # lock every post takes, so a burn racing this cannot take more than the
  # grant had left.
  #
  # Runs on all three exits, because all three end the application's part in
  # it. A claim is the one that is easy to miss: after it, the gate reads the
  # owner's balance (`billing_subject_id/1`), so an unspent grant left on the
  # principal would be money nobody could ever spend and nobody got back.
  defp settle_grant(%ClaimableUser{grant_cents: cents}, _opts) when cents <= 0, do: :ok

  defp settle_grant(%ClaimableUser{} = claimable, opts) do
    case Fountain.Credits.get_by_key(grant_key(claimable)) do
      %LedgerEntry{} = lot -> hand_back(claimable, lot, opts)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("settling principal #{claimable.user_id} failed: #{inspect(e)}")
      :ok
  end

  # `expire_lot/2` answers in three shapes and only one of them is money.
  # `{:ok, :nothing}` is a lot the principal spent to the last cent, which is
  # the common ending and has nothing to hand back; `{:ok, :duplicate, _}` is a
  # settle that already happened. Matching those as a refund is how a
  # `nil.amount_cents` becomes a rescued log line and a grant that silently
  # never returns.
  defp hand_back(%ClaimableUser{} = claimable, %LedgerEntry{} = lot, opts) do
    case Fountain.Credits.expire_lot(lot, actor: actor(opts)) do
      {:ok, %LedgerEntry{amount_cents: cents}} when cents < 0 ->
        Fountain.Credits.grant(
          claimable.application_user_id,
          abs(cents),
          "grant_application",
          idempotency_key: "principal_refund:#{claimable.id}",
          resource_type: "claimable_user",
          resource_id: claimable.id,
          actor: actor(opts)
        )

        :ok

      _ ->
        :ok
    end
  end

  defp actor(opts), do: Keyword.get(opts, :actor, "api")

  @doc "The ledger idempotency key the introductory grant was posted under."
  @spec grant_key(ClaimableUser.t()) :: String.t()
  def grant_key(%ClaimableUser{id: id}), do: "principal_grant:#{id}"

  @doc """
  Record, once, that a principal's budget ran out.

  Called from the credit gate when it refuses an unclaimed principal. The
  stamp is what makes it once: the gate runs on every door that spends, and a
  trail with one row per refused request is not a trail.

  Best-effort by rescuing, like every other write on a refusal path.
  """
  @spec note_budget_exhausted(binary()) :: :ok
  def note_budget_exhausted(user_id) when is_binary(user_id) do
    case _unsafe_get_by_principal(user_id) do
      %ClaimableUser{status: "unclaimed", budget_exhausted_at: nil} = c ->
        {:ok, c} =
          c
          |> Ecto.Changeset.change(budget_exhausted_at: DateTime.utc_now() |> truncate())
          |> Repo.update()

        record(c, "claimable_user.budget_exhausted", [actor: "system:credits"], %{
          "application_id" => c.application_id,
          "principal_id" => c.user_id,
          "grant_cents" => c.grant_cents
        })

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Delete principals whose grant closed more than `purge_after_days` ago.

  Goes through `Accounts.Deletion.delete_user/2`, the same teardown every
  other deletion uses, so nothing is left behind at a sandbox provider.
  Returns the number deleted.
  """
  @spec purge_closed(keyword()) :: non_neg_integer()
  def purge_closed(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cutoff = DateTime.add(now, -settings().purge_after_days * 86_400, :second)

    ClaimableUser
    |> where([c], c.status in ["expired", "released"])
    |> where([c], coalesce(c.expired_at, c.released_at) <= ^cutoff)
    |> limit(100)
    |> Repo.all()
    |> Enum.count(&purge_one/1)
  end

  defp purge_one(%ClaimableUser{} = claimable) do
    case Accounts.get_user(claimable.user_id) do
      nil ->
        false

      user ->
        match?({:ok, _}, Deletion.delete_user(user, actor: "system:principal_sweep"))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp stop_compute(user_id) do
    Deletion.destroy_sprites(user_id)
    :ok
  rescue
    e ->
      Logger.warning("stopping compute for principal #{user_id} failed: #{inspect(e)}")
      :ok
  end

  defp revoke_keys(user_id) do
    now = DateTime.utc_now() |> truncate()

    from(k in ApiKey, where: k.user_id == ^user_id and is_nil(k.revoked_at))
    |> Repo.update_all(set: [revoked_at: now])
  end

  # The audit row is written against the **application**, not the principal:
  # the application is the account a human reads a trail from, and a principal
  # that expires unclaimed is a tenant nobody can ever sign in to. A claim also
  # leaves a row on the claiming account, which is the only trail an owner has.
  defp record(%ClaimableUser{} = claimable, action, opts, metadata) do
    for user_id <-
          Enum.uniq(
            Enum.reject(
              [claimable.application_user_id, audit_owner(action, claimable)],
              &is_nil/1
            )
          ) do
      Audit.record(%{
        user_id: user_id,
        action: action,
        resource_type: "claimable_user",
        resource_id: claimable.id,
        actor: Keyword.get(opts, :actor, "api"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: metadata
      })
    end

    :ok
  end

  defp audit_owner("claimable_user.claimed", %ClaimableUser{claimed_by_user_id: id}), do: id
  defp audit_owner(_action, _claimable), do: nil

  defp new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  # Constant-time, and false for a grant with no live token — a claimed or
  # closed row holds `nil`, and `nil` must never compare equal to anything a
  # caller sends.
  defp valid_token?(%ClaimableUser{claim_token_hash: nil}, _token), do: false

  defp valid_token?(%ClaimableUser{claim_token_hash: hash}, token) when is_binary(token) do
    Plug.Crypto.secure_compare(hash, hash_token(token))
  end

  defp valid_token?(_claimable, _token), do: false

  defp truncate(dt), do: DateTime.truncate(dt, :second)

  defp as_integer(nil, default), do: default
  defp as_integer(n, _default) when is_integer(n), do: n

  defp as_integer(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp as_integer(_other, default), do: default

  # Dollars on the wire, cents in the ledger. A fractional dollar rounds down
  # so a budget is never quietly larger than what was asked for.
  defp usd_to_cents(nil), do: 0
  defp usd_to_cents(n) when is_integer(n), do: n * 100
  defp usd_to_cents(n) when is_float(n), do: trunc(Float.floor(n * 100))

  defp usd_to_cents(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> usd_to_cents(n)
      :error -> 0
    end
  end

  defp usd_to_cents(_other), do: 0

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
end
