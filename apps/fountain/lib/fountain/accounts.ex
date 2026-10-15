defmodule Fountain.Accounts do
  @moduledoc """
  Context for user accounts, API keys, per-tenant encryption keys, and OAuth identities.

  Does NOT own auth plugs, sessions, or LiveView hooks — those live in FountainWeb.

  ## Key functions

  - `register_user/1` — email+password registration; also creates a UserDataKey
  - `authenticate_user/2` — verify email + password for login
  - `get_user_by_email/1` — lookup by email
  - `get_user/1` — lookup by id
  - `verify_email/1` — set email_verified_at on the user
  - `reset_password/2` — update password hash + bump session_version
  - `create_api_key/2` — issue a new API key (returns the plaintext once)
  - `revoke_api_key/2` — permanently invalidate a key
  - `authenticate_api_key/1` — authenticate a raw API key string
  - `touch_api_key/1` — update last_used_at at most once a minute (best-effort, off the request)
  - `upsert_oauth_user/3` — find-or-create user from OAuth callback
  """

  import Ecto.Query
  require Logger
  alias Fountain.Repo
  alias Fountain.Accounts.{User, ApiKey, UserDataKey, OauthIdentity}
  alias Fountain.Audit
  alias Fountain.Audit.AdminEvent
  alias Fountain.Crypto

  ## Users

  @doc "Look up a user by (downcased) email. Returns `nil` if not found."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc "Load a user by id. Returns `nil` if not found."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  @doc """
  Whether a new account may be created on this instance.

  Registration was open to the world with no way to close it: a self-hoster
  exposing an instance had no control over who signed up. `REGISTRATION_ENABLED`
  is the one control (ADR 0011); the email-domain allowlist and the access code
  were removed on 2026-10-15.

  Checked in the context rather than the controller because there are three
  ways to create an account — the HTML form, the JSON endpoint, and an OAuth
  callback for an unrecognised identity. A control that only covers the form is
  not a control.
  """
  @spec registration_allowed?() :: :ok | {:error, :registration_closed}
  def registration_allowed? do
    if registration_enabled?(), do: :ok, else: {:error, :registration_closed}
  end

  @doc """
  Whether registration is open at all.

  `REGISTRATION_ENABLED` has three states (ADR 0011, 2026-10-14 addendum):
  `true` and `false` are the operator's explicit choice; unset (`:auto`, the
  default) leaves self-registration open only until the instance has had an
  admin (`admin_bootstrapped?/0`). A default install is open long enough for
  its operator to create the first account, and closed to strangers after.

  For a front door deciding whether to offer a "create an account" link: a link
  that leads to a refusal is worse than no link. It is not a control —
  `registration_allowed?/0` stays the thing that refuses the submit, on all
  three paths.
  """
  @spec registration_enabled?() :: boolean()
  def registration_enabled? do
    case Application.get_env(:fountain, :registration_enabled, :auto) do
      true -> true
      false -> false
      :auto -> not admin_bootstrapped?()
    end
  end

  @doc """
  Whether this instance has ever had an admin.

  True while any account holds the admin role, and also after the last admin
  is demoted or deleted: every route that grants the role — the first-admin
  bootstrap, the admin UI and the admin API — records `admin.role.granted` in `admin_audit_events`, the privilege
  trail the retention pruner deliberately never prunes (#452) and which has
  no foreign key to `users`, so a deleted admin's grant outlives the account.

  This is what keeps the first-admin bootstrap from re-arming and keeps
  `:auto` registration closed once an operator has taken the instance.
  """
  @spec admin_bootstrapped?() :: boolean()
  def admin_bootstrapped? do
    Repo.exists?(from(u in User, where: u.role == "admin")) or
      Repo.exists?(from(e in AdminEvent, where: e.event_type == "admin.role.granted"))
  end

  @doc """
  Register a new user with email + password.

  Also creates a `UserDataKey` row in the same transaction, wrapping a freshly
  generated DEK with the platform master key.

  Returns `{:ok, user}`, `{:error, changeset}`, or
  `{:error, :registration_closed}`.

  Audited as `account.registered`. Recorded here rather than in the two
  controllers because `POST /api/auth/register` sits on `:api_public`, which
  carries no audit plug — so the JSON signup door left no record at all, while
  the OAuth variant recorded `auth.oauth.signup` and the browser form recorded
  nothing (#544). `opts` carries `:actor` / `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface.
  """
  @spec register_user(map(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def register_user(attrs, opts \\ []) do
    with :ok <- registration_allowed?() do
      # Audits outside `do_register_user/1`, whose body is a transaction: a
      # failed audit insert inside one aborts the enclosing transaction, so
      # recording in there could roll back the very registration it is
      # describing. after_auto_verify/2 is on the same side of the commit.
      attrs |> do_register_user() |> audited_registration(opts) |> after_auto_verify(opts)
    end
  end

  defp audited_registration({:ok, %User{} = user} = ok, opts) do
    Audit.record(%{
      user_id: user.id,
      action: "account.registered",
      resource_type: "user",
      resource_id: user.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"email" => user.email}
    })

    ok
  end

  defp audited_registration(other, _opts), do: other

  @doc """
  Open an account on behalf of `admin` (ADR 0064): verified, with no
  password, and with one full-scope API key, returned in plaintext here and
  never again.

  This is the operator's door, so registration's own gate
  (`REGISTRATION_ENABLED`) does not apply;
  the admin pipeline in front of it is the gate. Audited as
  `account.created_by_admin` and `api_key.created`, both naming the admin.

  Options: `:key_name` (default `"platform"`).

  Returns `{:ok, {user, raw_key}}` or `{:error, changeset}`.
  """
  @spec create_account_by_admin(User.t(), String.t(), keyword()) ::
          {:ok, {User.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_account_by_admin(%User{role: "admin"} = admin, email, opts \\ [])
      when is_binary(email) do
    actor = "admin:#{admin.id}"

    result =
      Repo.transaction(fn ->
        with {:ok, user} <- Repo.insert(User.admin_created_changeset(%User{}, %{email: email})),
             {:ok, _udk} <- create_user_data_key(user.id),
             {changeset, raw} = build_api_key(user.id, Keyword.get(opts, :key_name, "platform")),
             {:ok, key} <- Repo.insert(changeset) do
          {user, key, raw}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, {user, key, raw}} <- result do
      # After the commit: a failed audit insert inside the transaction would
      # roll back the account it describes (see audited_registration/2).
      record_api_key_created(key, actor: actor, request_ip: Keyword.get(opts, :request_ip))

      Audit.record(%{
        user_id: user.id,
        action: "account.created_by_admin",
        resource_type: "user",
        resource_id: user.id,
        actor: actor,
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{"email" => user.email}
      })

      # The account is inserted verified, so it runs what a verification sets
      # off, after the commit and after its own audit rows. The first-admin
      # bootstrap in there is a no-op: `admin` holds the role, so
      # `admin_bootstrapped?/0` is already true, and the new account stays a
      # `user` as decision 1 requires.
      {:ok, {after_verification(user), raw}}
    end
  end

  # With mail off (no SMTP_HOST) the verification link can never be
  # delivered, so requiring it gates nothing and dead-ends every
  # email+password signup.
  # Verify at creation instead: the row is inserted verified, inside the
  # transaction, and what verification sets off — its audit row and the
  # first-admin bootstrap — runs after the commit in
  # after_auto_verify/2, as it does on every other verification route.
  # Running them inside the transaction wrote audit rows there (ADR 0013).
  defp do_register_user(attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <- insert_user(attrs, :password, auto_verify?()),
           {:ok, _udk} <- create_user_data_key(user.id) do
        user
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp auto_verify?, do: not Application.get_env(:fountain, :email_enabled, true)

  defp after_auto_verify({:ok, %User{email_verified_at: %DateTime{}} = user}, opts) do
    record_account_event(user, "auth.email.verified", "user", opts, %{})
    {:ok, after_verification(user)}
  end

  defp after_auto_verify(other, _opts), do: other

  @doc """
  Verify a user's email address by setting `email_verified_at` to now.

  Verification is also the first-admin bootstrap hook (ADR 0011): the first
  account to become verified on an instance that has never had an admin
  (`admin_bootstrapped?/0`) comes back promoted. There is no switch for it.
  Hooked here rather than at registration so the grant always lands on a
  login-capable account — an unverified registration holding the role would
  close `:auto` registration and strand the instance — and so every
  verification route behaves the same: the emailed link,
  `Fountain.Release.verify_email/1`, and the mail-off auto-verify and an
  OAuth signup, which run the same steps after their own commit. An
  admin-created account runs them too, as a no-op: its creator is an admin.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec verify_email(User.t(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def verify_email(%User{} = user, opts \\ []) do
    result =
      user
      |> Ecto.Changeset.change(
        email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update()
      |> audited_account("auth.email.verified", "user", opts, fn _ -> %{} end)

    with {:ok, verified} <- result do
      {:ok, after_verification(verified)}
    end
  end

  # What a verification sets off, on every route that verifies: verify_email/2,
  # the mail-off auto-verify in register_user/2, an OAuth signup
  # in upsert_oauth_user/3, which inserts the account already verified, and an
  # admin-created account in create_account_by_admin/3 (ADR 0064). A new
  # door that creates a verified account calls this too, or its accounts miss
  # the first-admin bootstrap. It writes audit rows, so a caller runs this
  # after its transaction commits, never inside one (ADR 0013).
  defp after_verification(%User{} = user), do: maybe_bootstrap_first_admin(user)

  # Advisory lock key for the first-admin bootstrap. Any stable bigint works;
  # it only has to be distinct from other advisory locks this app takes.
  @first_admin_lock 0xF057AD

  defp maybe_bootstrap_first_admin(%User{role: "admin"} = user), do: user

  # Always on in every deployed environment; there is no variable for it
  # (ADR 0011, 2026-10-15 addendum). `config/test.exs` turns it off, because
  # every test's sandbox is an instance that has never had an admin and would
  # otherwise promote its first verified account; the bootstrap's own tests
  # turn it back on.
  defp maybe_bootstrap_first_admin(%User{} = user) do
    if Application.get_env(:fountain, :first_admin_bootstrap, true) do
      bootstrap_first_admin(user)
    else
      user
    end
  end

  # Promotion is best-effort on the same terms as audit logging: the account
  # is already verified, and failing that with a bootstrap error would read as
  # a broken signup. The advisory xact lock serializes concurrent first
  # verifications so exactly one can see "no admin has ever existed".
  #
  # "Ever", not "now" (ADR 0011, 2026-10-14 addendum): checking only for a
  # current admin let the switch re-arm when the last admin was demoted or
  # deleted, and the next account to verify was handed the instance.
  #
  # The grant is audited after the transaction commits, never inside it
  # (ADR 0013): a failed audit insert would abort the promotion with it.
  defp bootstrap_first_admin(%User{} = user) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@first_admin_lock])

      if admin_bootstrapped?() do
        user
      else
        # Not update_user_role/3: it audits, and this is inside a transaction.
        case user |> Ecto.Changeset.change(role: "admin") |> Repo.update() do
          {:ok, promoted} ->
            promoted

          {:error, changeset} ->
            Logger.error("first_user_admin: promotion failed: #{inspect(changeset.errors)}")
            user
        end
      end
    end)
    |> case do
      {:ok, %User{role: "admin"} = promoted} ->
        record_account_event(
          promoted,
          "account.role_changed",
          "user",
          [actor: "system:first_user_admin"],
          %{"from" => user.role, "to" => "admin"}
        )

        Fountain.Audit.record_admin(%{
          actor_user_id: nil,
          target_user_id: promoted.id,
          event_type: "admin.role.granted",
          metadata: %{
            "email" => promoted.email,
            "from" => user.role,
            "to" => "admin",
            "via" => "first_user_admin"
          }
        })

        promoted

      {:ok, unchanged} ->
        unchanged

      {:error, reason} ->
        Logger.error("first_user_admin: bootstrap transaction failed: #{inspect(reason)}")
        user
    end
  end

  @doc """
  Authenticate a user by email and password.

  Returns `{:ok, user}` on success, or one of:
  - `{:error, :not_found}` — no user with that email
  - `{:error, :wrong_password}` — user exists but password doesn't match
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :not_found | :wrong_password}
  def authenticate_user(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    if user do
      cond do
        # OAuth-only accounts have no password_hash; verify_pass would raise,
        # turning POST /auth/login into a 500 that doubles as an
        # account-existence oracle (#324). Burn the same dummy verify as the
        # no-user branch so the timing shape stays uniform, and answer
        # exactly what any bad password gets.
        is_nil(user.password_hash) ->
          Bcrypt.no_user_verify()
          {:error, :wrong_password}

        not Bcrypt.verify_pass(password, user.password_hash) ->
          {:error, :wrong_password}

        true ->
          {:ok, user}
      end
    else
      # Constant-time dummy verify to prevent timing-based enumeration
      Bcrypt.no_user_verify()
      {:error, :not_found}
    end
  end

  @doc """
  Reset a user's password.

  Updates `password_hash` and bumps `session_version` to invalidate all
  existing sessions.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec reset_password(User.t(), String.t(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_password(%User{} = user, new_password, opts \\ []) when is_binary(new_password) do
    set_password(user, new_password, "auth.password.reset", opts)
  end

  # Shared by the reset and change paths, which write the same columns but are
  # not the same event: a reset is someone who could not get in proving control
  # of the mailbox, a change is someone already signed in. Both were recorded
  # by their controllers — four call sites for two events (#593).
  defp set_password(%User{} = user, new_password, action, opts) do
    user
    |> User.password_reset_changeset(%{password: new_password})
    |> User.invalidate_sessions_changeset()
    |> Repo.update()
    |> audited_account(action, "user", opts, fn _ -> %{} end)
  end

  # ── password change (#448) ──────────────────────────────────────────────

  @doc """
  Change a logged-in user's password (#448).

  Requires the current password — a stolen session must not be enough to set
  a new one. Delegates to `reset_password/2`, so `session_version` bumps and
  every other session dies; the calling controller re-issues the current
  session from the updated user. OAuth-only accounts (nil `password_hash`)
  are refused — they set a first password through the reset flow.
  """
  @spec change_password(User.t(), String.t(), String.t(), keyword()) ::
          {:ok, User.t()}
          | {:error, :no_password | :invalid_current_password | Ecto.Changeset.t()}
  def change_password(user, current, new, opts \\ [])

  def change_password(%User{password_hash: nil}, _current, _new, _opts),
    do: {:error, :no_password}

  def change_password(%User{} = user, current, new, opts)
      when is_binary(current) and is_binary(new) do
    if Bcrypt.verify_pass(current, user.password_hash) do
      # Not `reset_password/3`: the columns are the same but the event is not.
      set_password(user, new, "auth.password.changed", opts)
    else
      {:error, :invalid_current_password}
    end
  end

  @doc """
  Find or create a user from an OAuth provider callback.

  Looks up by `(provider, provider_uid)` first; falls back to email lookup
  to link an existing account. Creates a new user if neither matches.

  For new users: skips email verification (provider-verified email is trusted),
  creates a `UserDataKey`, and creates an `OauthIdentity` row. After the
  commit it runs what any verification sets off, as `verify_email/2` does: the
  first-admin bootstrap.

  For existing users: upserts the `OauthIdentity` row (safe to call on
  every login).

  A brand-new identity passes the same registration gate as the forms; a
  returning or linked identity is not gated.

  Returns `{:ok, user, :new | :existing}` or `{:error, changeset}`.
  """
  # The error can also be :registration_closed: a brand-new OAuth
  # identity on a closed instance rolls the transaction back with it. The spec
  # used to omit the atoms, which made dialyzer condemn the controller branch
  # that handles them as unreachable — it is not.
  @spec upsert_oauth_user(String.t(), String.t(), map()) ::
          {:ok, User.t(), :new | :existing}
          | {:error, Ecto.Changeset.t() | :registration_closed}
  def upsert_oauth_user(provider, provider_uid, attrs)
      when is_binary(provider) and is_binary(provider_uid) do
    Repo.transaction(fn ->
      existing_identity =
        Repo.get_by(OauthIdentity, provider: provider, provider_uid: provider_uid)

      case existing_identity do
        %OauthIdentity{user_id: user_id} ->
          user = Repo.get!(User, user_id)
          {:ok, user, :existing}

        nil ->
          email = String.downcase(attrs[:email] || attrs["email"] || "")

          case Repo.get_by(User, email: email) do
            %User{} = user ->
              # Link the existing account to this OAuth identity
              with {:ok, _} <- insert_oauth_identity(user.id, provider, provider_uid) do
                {:ok, user, :existing}
              else
                {:error, cs} -> Repo.rollback(cs)
              end

            nil ->
              # Brand-new user from OAuth — a registration like any other, and
              # the path most likely to be forgotten by a controller-level gate.
              case registration_allowed?() do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              verified_at = DateTime.utc_now() |> DateTime.truncate(:second)

              with {:ok, user} <-
                     insert_user(
                       Map.merge(attrs, %{
                         "email" => email,
                         "email_verified_at" => verified_at
                       }),
                       :oauth
                     ),
                   {:ok, _udk} <- create_user_data_key(user.id),
                   {:ok, _} <- insert_oauth_identity(user.id, provider, provider_uid) do
                {:ok, user, :new}
              else
                {:error, cs} -> Repo.rollback(cs)
              end
          end
      end
    end)
    |> case do
      # OAuth stamps email_verified_at at insert rather than going through
      # verify_email/1, so it runs what a verification sets off itself — the
      # first-admin bootstrap (ADR 0011) — after the commit, because it
      # writes audit rows (ADR 0013).
      {:ok, {:ok, user, :new}} -> {:ok, after_verification(user), :new}
      {:ok, {:ok, user, status}} -> {:ok, user, status}
      {:ok, result} -> result
      {:error, _} = err -> err
    end
  end

  ## API keys

  @doc """
  Generate and persist a new API key for `user_id` with the given human-readable `name`.

  The raw key is `"ftn_" <> 64 hex chars`. It is returned once and never stored.
  Only the SHA-256 hash and the first 8-character prefix are persisted.

  Minting is audited here rather than by each caller. There are four ways to
  get a key — the settings LiveView, `POST /api/auth/api-keys`, `POST
  /api/auth/token` and the per-conversation callback rotation — and only the
  first two used to leave a trail. `/api/auth/token` sits on `:api_public`, so
  the pipeline's audit plug never saw it: the one path that exchanges a
  password for a full-scope key was the only one that minted silently (#542).

  Options:

    * `:scopes` — defaults to `["full"]`
    * `:expires_at` — defaults to no expiry
    * `:actor` — who minted it, for the audit trail. Defaults to `"self"`;
      pass `FountainWeb.Audited.attribution/2` from a web surface, or a
      `"system:<worker>"` string from a background one.
    * `:request_ip` — passed through to the audit event.

  Returns `{:ok, {%ApiKey{}, raw_key_string}}` or `{:error, changeset}`.
  """
  @spec create_api_key(binary(), String.t(), keyword()) ::
          {:ok, {ApiKey.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_api_key(user_id, name, opts \\ []) when is_binary(user_id) and is_binary(name) do
    {changeset, raw} = build_api_key(user_id, name, opts)

    with {:ok, key} <- Repo.insert(changeset) do
      record_api_key_created(key, opts)
      {:ok, {key, raw}}
    end
  end

  @doc """
  Mint an admin key, scopes `["full", "admin"]`, for an account with the admin
  role (#2660).

  The one way to get a key that `/api/admin` admits. `create_api_key/3` and
  `build_api_key/3` refuse the `admin` scope, so OAuth, `POST /api/auth/token`
  and `POST /api/auth/api-keys` cannot mint one. Its callers are the admin's
  own Account → API keys page and `Fountain.Release.create_admin_key/2`.

  Audited as `api_key.created`, with `"admin"` among the recorded scopes. Takes
  the same `:actor`, `:request_ip` and `:expires_at` options as
  `create_api_key/3`. Returns `{:error, :not_admin}` for any other role.
  """
  @spec create_admin_api_key(User.t(), String.t(), keyword()) ::
          {:ok, {ApiKey.t(), String.t()}} | {:error, :not_admin | Ecto.Changeset.t()}
  def create_admin_api_key(user, name, opts \\ [])

  def create_admin_api_key(%User{role: "admin", id: user_id}, name, opts)
      when is_binary(name) do
    {changeset, raw} =
      do_build_api_key(user_id, name, Keyword.put(opts, :scopes, ApiKey.admin_scopes()))

    with {:ok, key} <- Repo.insert(changeset) do
      record_api_key_created(key, opts)
      {:ok, {key, raw}}
    end
  end

  def create_admin_api_key(%User{}, _name, _opts), do: {:error, :not_admin}

  @doc """
  Build a key changeset and plaintext without persistence; transactional
  callers audit after commit.

  Raises on the `admin` scope: only `create_admin_api_key/3` mints that (#2660).
  """
  def build_api_key(user_id, name, opts \\ []) do
    if "admin" in Keyword.get(opts, :scopes, []) do
      raise ArgumentError, "the admin scope is minted only by create_admin_api_key/3"
    end

    do_build_api_key(user_id, name, opts)
  end

  defp do_build_api_key(user_id, name, opts) do
    raw = "ftn_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    changeset =
      ApiKey.changeset(%ApiKey{}, %{
        user_id: user_id,
        name: name,
        key_hash: hash_key(raw),
        key_prefix: String.slice(raw, 0, 8),
        scopes: Keyword.get(opts, :scopes, ["full"]),
        expires_at: Keyword.get(opts, :expires_at)
      })

    {changeset, raw}
  end

  @doc "Record a committed key mint; call outside the transaction that inserted it."
  def record_api_key_created(%ApiKey{} = key, opts \\ []) do
    Audit.record(%{
      user_id: key.user_id,
      action: "api_key.created",
      resource_type: "api_key",
      resource_id: key.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "name" => key.name,
        "scopes" => key.scopes,
        "key_prefix" => key.key_prefix
      }
    })
  end

  @doc """
  Revoke an API key by setting `revoked_at` to now. Only the owning user's key is revoked
  (pass `user_id` to prevent one user revoking another's key; admins have a separate path).

  Revocation is permanent — revoked keys cannot be un-revoked.

  Returns `{:ok, api_key}` or `{:error, :not_found}`.
  """
  @spec revoke_api_key(binary(), binary(), keyword()) ::
          {:ok, ApiKey.t()} | {:error, :not_found}
  def revoke_api_key(user_id, key_id, opts \\ [])
      when is_binary(user_id) and is_binary(key_id) do
    case Repo.get_by(ApiKey, id: key_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      key ->
        key
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
        |> case do
          {:ok, revoked} -> record_api_key_revoked(revoked, opts)
          error -> error
        end
    end
  end

  @doc "Audit a committed key revocation outside the transaction that changed it."
  def record_api_key_revoked(%ApiKey{} = key, opts \\ []) do
    audited_account({:ok, key}, "api_key.revoked", "api_key", opts, fn revoked ->
      %{"name" => revoked.name, "key_prefix" => revoked.key_prefix}
    end)
  end

  @doc """
  Authenticate a raw API key and return the key record alongside the user.

  The auth plug needs the record, not just the user: scope is carried on the key,
  so a caller holding a sandbox token is otherwise indistinguishable from the
  human who owns the tenant.

  Returns `{:ok, user, api_key}`, or
  `{:error, :revoked | :expired | :unverified | :not_found}`.
  """
  @spec authenticate_api_key(String.t()) ::
          {:ok, User.t(), ApiKey.t()}
          | {:error, :revoked | :expired | :unverified | :not_found}
  def authenticate_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    query =
      from k in ApiKey,
        where: k.key_hash == ^key_hash,
        join: u in assoc(k, :user),
        preload: [user: u]

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %ApiKey{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :revoked}

      %ApiKey{} = key ->
        cond do
          ApiKey.expired?(key) ->
            {:error, :expired}

          # Asserted here rather than only where keys are minted (#533). Every
          # minting path already refuses an unverified account, so this changes
          # nothing for a key issued today — but that made four call sites the
          # invariant depended on, and a fifth would have reopened the gap in
          # silence. Keys predating #314, when `POST /api/auth/token` would mint
          # for an unverified account, stop working here: that is the point.
          is_nil(key.user.email_verified_at) ->
            {:error, :unverified}

          true ->
            {:ok, key.user, key}
        end
    end
  end

  @api_key_touch_interval_s 60

  @doc """
  Whether `key`'s `last_used_at` is old enough that `touch_api_key/1` would
  write it. Lets the caller skip the task and the query for a key it has just
  read as freshly stamped.
  """
  @spec api_key_touch_due?(ApiKey.t()) :: boolean()
  def api_key_touch_due?(%ApiKey{last_used_at: nil}), do: true

  def api_key_touch_due?(%ApiKey{last_used_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) >= @api_key_touch_interval_s

  @doc """
  Update `last_used_at` for the API key matching `raw_key`.

  Called from an unlinked task under `Fountain.TaskSupervisor` (see
  `FountainWeb.Plugs.TenantAPIAuth`) so it does not block the request, and
  best-effort *by rescuing*, the position `Audit.record/1` takes for the same
  reason: a failed stamp on a column nothing reads on the hot path is a log
  line, never the reason an already-authenticated request fails (#1040).

  The stamp is at most a minute old rather than exact (#2563). Every
  authenticated request used to write the key's row, and a client sending
  requests in parallel on one key queued them on its row lock, up to 2.7 s
  each while holding a pool connection. A key stamped within the last minute
  is left alone, so a burst writes once.

  Always returns `:ok`.
  """
  @spec touch_api_key(String.t()) :: :ok
  def touch_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale = DateTime.add(now, -@api_key_touch_interval_s)

    from(k in ApiKey,
      where: k.key_hash == ^key_hash,
      where: is_nil(k.last_used_at) or k.last_used_at < ^stale
    )
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  rescue
    e ->
      Logger.warning("touch_api_key: last_used_at stamp failed: #{inspect(e)}")
      :ok
  end

  ## Internal helpers

  defp insert_user(attrs, kind, verified? \\ false)

  defp insert_user(attrs, :password, false) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  defp insert_user(attrs, :password, true) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(
      :email_verified_at,
      DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.insert()
  end

  defp insert_user(attrs, :oauth, _verified?) do
    %User{}
    |> User.oauth_registration_changeset(attrs)
    |> Repo.insert()
  end

  defp create_user_data_key(user_id) do
    dek = Crypto.generate_dek()
    wrapped = Crypto.wrap_dek(dek)

    %UserDataKey{}
    |> UserDataKey.changeset(%{user_id: user_id, wrapped_key: wrapped})
    |> Repo.insert()
  end

  defp insert_oauth_identity(user_id, provider, provider_uid) do
    %OauthIdentity{}
    |> OauthIdentity.changeset(%{
      user_id: user_id,
      provider: provider,
      provider_uid: provider_uid
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:provider, :provider_uid])
  end

  @doc "List all active (non-revoked) API keys for a user, newest first."
  def list_api_keys(user_id) when is_binary(user_id) do
    from(k in ApiKey,
      where: k.user_id == ^user_id and is_nil(k.revoked_at),
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  @sortable_columns %{
    "email" => :email,
    "joined" => :inserted_at,
    "last_activity" => :last_activity
  }

  @doc """
  Filtered, sorted, paginated user listing for the admin panel.

  Options:

  - `:search` — case-insensitive email substring
  - `:role` — `"admin"` or `"user"`
  - `:verified` — `true`/`false` (whether `email_verified_at` is set)
  - `:sort` — `"email"`, `"joined"`, or `"last_activity"`
    (unknown values fall back to `"joined"`)
  - `:dir` — `"asc"` or `"desc"` (default `"desc"`)
  - `:page` / `:per_page` — 1-based offset pagination

  Returns `%{users: users, total: filtered_count}`. Each user carries a
  `:last_activity_at` key (when its latest turn started, `nil` if none) — sorting by it
  needs the join anyway, so every caller gets the value for free.
  """
  @spec list_users_admin(keyword()) :: %{users: [User.t()], total: non_neg_integer()}
  def list_users_admin(opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> max(1)
    per_page = Keyword.get(opts, :per_page, 25)

    base = filter_users(opts)
    total = Repo.aggregate(base, :count)

    users =
      base
      |> join(:left, [u], a in subquery(last_activity_query()),
        on: a.user_id == u.id,
        as: :activity
      )
      |> order_users(Keyword.get(opts, :sort), Keyword.get(opts, :dir, "desc"))
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> select([u, activity: a], {u, a.last_at})
      |> Repo.all()
      |> Enum.map(fn {user, last_at} -> Map.put(user, :last_activity_at, last_at) end)

    %{users: users, total: total}
  end

  defp filter_users(opts) do
    Enum.reduce(opts, from(u in User), fn
      {:search, term}, q when is_binary(term) and term != "" ->
        where(q, [u], ilike(u.email, ^"%#{sanitize_like(term)}%"))

      {:role, role}, q when role in ~w(admin user) ->
        where(q, [u], u.role == ^role)

      {:verified, true}, q ->
        where(q, [u], not is_nil(u.email_verified_at))

      {:verified, false}, q ->
        where(q, [u], is_nil(u.email_verified_at))

      _, q ->
        q
    end)
  end

  defp last_activity_query do
    from(t in Fountain.Conversations.Turn,
      join: c in Fountain.Conversations.Conversation,
      on: c.id == t.conversation_id,
      group_by: c.user_id,
      select: %{user_id: c.user_id, last_at: max(t.inserted_at)}
    )
  end

  defp order_users(query, sort, dir) do
    dir = if dir == "asc", do: :asc, else: :desc

    case Map.get(@sortable_columns, sort, :inserted_at) do
      :last_activity ->
        # nulls always sink so never-active accounts don't bury the signal
        dir = if dir == :asc, do: :asc_nulls_last, else: :desc_nulls_last
        order_by(query, [u, activity: a], [{^dir, a.last_at}, {:asc, u.id}])

      column ->
        order_by(query, [u], [{^dir, field(u, ^column)}, {:asc, u.id}])
    end
  end

  defp sanitize_like(term) do
    String.replace(term, ~r/[\\%_]/, fn ch -> "\\" <> ch end)
  end

  @doc "Update a user's role. Role must be 'admin' or 'user'."
  def update_user_role(%User{} = user, role, opts \\ []) when role in ~w(admin user) do
    user
    |> Ecto.Changeset.change(role: role)
    |> Repo.update()
    |> audited_account("account.role_changed", "user", opts, fn updated ->
      %{"from" => user.role, "to" => updated.role}
    end)
  end

  @doc false
  def hash_key(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  # Shared by the account-level mutations above. Each of these used to depend
  # on its caller remembering: the admin LiveView recorded through
  # `record_admin/1`, the API surface recorded through the pipeline plug, and
  # anything else recorded nothing (#552). The context records the tenant-facing
  # event; the admin surfaces still add their own `admin_audit_events` row on
  # top, because those carry an actor AND a target, which `audit_events` cannot
  # express.
  defp audited_account({:ok, record} = ok, action, resource_type, opts, metadata_fun) do
    Audit.record(%{
      user_id: Map.get(record, :user_id) || Map.get(record, :id),
      action: action,
      resource_type: resource_type,
      resource_id: record.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata_fun.(record)
    })

    ok
  end

  defp audited_account(other, _action, _resource_type, _opts, _metadata_fun), do: other

  defp record_account_event(%User{} = user, action, resource_type, opts, metadata) do
    Audit.record(%{
      user_id: user.id,
      action: action,
      resource_type: resource_type,
      resource_id: user.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata
    })
  end
end
