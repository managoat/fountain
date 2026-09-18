defmodule Fountain.Accounts do
  @moduledoc """
  Context for user accounts, API keys, per-tenant encryption keys, and OAuth identities.

  Does NOT own auth plugs, sessions, or LiveView hooks — those live in FountainWeb.

  ## Key functions

  - `register_user/1` — email+password registration; also creates a UserDataKey
  - `authenticate_user/2` — verify email + password for login
  - `get_user_by_email/1` — lookup by email
  - `get_user/1` / `get_user!/1` — lookup by id
  - `verify_email/1` — set email_verified_at on the user
  - `reset_password/2` — update password hash + bump session_version
  - `create_api_key/2` — issue a new API key (returns the plaintext once)
  - `revoke_api_key/2` — permanently invalidate a key
  - `get_user_by_api_key/1` — authenticate a raw API key string
  - `touch_api_key/1` — update last_used_at (best-effort, off the request)
  - `upsert_oauth_user/3` — find-or-create user from OAuth callback
  """

  import Ecto.Query
  require Logger
  alias Fountain.Repo
  alias Fountain.Accounts.{User, ApiKey, UserDataKey, OauthIdentity}
  alias Fountain.Audit
  alias Fountain.Conversations.Termination
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

  @doc "Load a user by id. Raises `Ecto.NoResultsError` if not found."
  @spec get_user!(binary()) :: User.t()
  def get_user!(id) when is_binary(id), do: Repo.get!(User, id)

  @doc """
  Whether `email` may create an account on this instance.

  Registration was open to the world with no way to close it: a self-hoster
  exposing an instance had no control over who signed up, and on the hosted side
  every signup consumes the platform Sprites token.

  Checked in the context rather than the controller because there are three
  ways to create an account — the HTML form, the JSON endpoint, and an OAuth
  callback for an unrecognised identity. A control that only covers the form is
  not a control.
  """
  @spec registration_allowed?(String.t() | nil, String.t() | nil) :: :ok | {:error, atom()}
  def registration_allowed?(email, access_code \\ nil) do
    cond do
      not registration_enabled?() ->
        {:error, :registration_closed}

      not domain_allowed?(email) ->
        {:error, :email_domain_not_allowed}

      not access_code_valid?(access_code) ->
        {:error, :access_code_required}

      true ->
        :ok
    end
  end

  @doc """
  Whether signup on this instance asks for an access code
  (`REGISTRATION_ACCESS_CODE`), so a form knows to show the field.
  """
  @spec access_code_required?() :: boolean()
  def access_code_required?, do: configured_access_code() != nil

  @doc """
  Whether `code` opens registration. Always true when no code is configured.

  Surrounding whitespace is ignored: a code is typed or pasted by hand.
  """
  @spec access_code_valid?(String.t() | nil) :: boolean()
  def access_code_valid?(code) do
    case configured_access_code() do
      nil -> true
      expected when is_binary(code) -> Plug.Crypto.secure_compare(String.trim(code), expected)
      _ -> false
    end
  end

  defp configured_access_code do
    case Application.get_env(:fountain, :registration_access_code) do
      code when is_binary(code) and code != "" -> code
      _ -> nil
    end
  end

  @doc """
  Whether registration is open at all, with no email in hand.

  For a front door deciding whether to offer a "create an account" link: a link
  that leads to a refusal is worse than no link. It is not a control —
  `registration_allowed?/1` stays the thing that refuses the submit, on all
  three paths.
  """
  @spec registration_enabled?() :: boolean()
  def registration_enabled?, do: Application.get_env(:fountain, :registration_enabled, true)

  defp domain_allowed?(email) do
    case Application.get_env(:fountain, :registration_allowed_email_domains, []) do
      [] ->
        true

      domains ->
        case String.split(to_string(email), "@") do
          [_, domain] -> String.downcase(domain) in domains
          _ -> false
        end
    end
  end

  @doc """
  Register a new user with email + password.

  Also creates a `UserDataKey` row in the same transaction, wrapping a freshly
  generated DEK with the platform master key.

  Returns `{:ok, user}`, `{:error, changeset}`, or `{:error, reason}` when
  registration is closed, the email domain is not allowed, or the instance
  asks for an access code (`"access_code"` in `attrs`) that was not given.

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
    email = attrs["email"] || attrs[:email]

    with :ok <- registration_allowed?(email, attrs["access_code"] || attrs[:access_code]) do
      # Outside `do_register_user/1`, whose body is a transaction: a failed
      # audit insert inside one aborts the enclosing transaction, so recording
      # in there could roll back the very registration it is describing.
      attrs |> do_register_user() |> audited_registration(opts)
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

  defp do_register_user(attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <- insert_user(attrs),
           {:ok, _udk} <- create_user_data_key(user.id),
           {:ok, user} <- maybe_auto_verify(user) do
        user
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # With EMAIL_DELIVERY=none the verification link can never be delivered, so
  # requiring it gates nothing and dead-ends every email+password signup.
  # Verify at creation instead. Goes through verify_email/1 so the first-admin
  # bootstrap fires here too — on such an instance this IS the verification.
  defp maybe_auto_verify(%User{} = user) do
    if Application.get_env(:fountain, :email_enabled, true) do
      {:ok, user}
    else
      verify_email(user)
    end
  end

  @doc """
  Verify a user's email address by setting `email_verified_at` to now.

  Verification is also the first-admin bootstrap hook (ADR 0011): with
  `FIRST_USER_ADMIN=true`, the first account to become verified on an instance
  with no admin comes back promoted. Hooked here rather than at registration
  so the grant always lands on a login-capable account, and so every
  verification route — the emailed link, `Fountain.Release.verify_email/1`,
  and the `EMAIL_DELIVERY=none` auto-verify — behaves the same.

  It is also where an account gets the two things it is meant to have before
  it has built anything: the opening credit (ADR 0031) and the starter agent
  (ADR 0038, `Fountain.Agents.Starter`). Both are best-effort and neither can
  fail a verification.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec verify_email(User.t(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def verify_email(%User{} = user, opts \\ []) do
    # The before-state, read before the update overwrites it: the starter
    # agent lands on the transition, not on every call of this function.
    first_verification? = is_nil(user.email_verified_at)

    result =
      user
      |> Ecto.Changeset.change(
        email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update()
      |> tap(&grant_opening_credit/1)
      |> audited_account("auth.email.verified", "user", opts, fn _ -> %{} end)

    with {:ok, verified} <- result do
      verified = maybe_bootstrap_first_admin(verified)
      plant_starter_agent(verified, first_verification?)
      broadcast_verification(verified)
      {:ok, verified}
    end
  end

  # The opening credit (ADR 0031 decision 3) lands on the verification
  # transition, whichever door finished it: the browser route, the API, or
  # an OAuth signup that arrives verified. Best-effort by rescuing — a ledger
  # hiccup must not fail a verification — and idempotent per account.
  defp grant_opening_credit({:ok, %User{} = user}) do
    Fountain.Credits.grant_opening(user)
    :ok
  rescue
    e -> Logger.warning("opening credit for #{user.id} failed: #{inspect(e)}")
  end

  defp grant_opening_credit(_), do: :ok

  # The default agent (ADR 0038 decision 4) is planted beside the opening
  # credit, for the same reason and on the same transition: a verified account
  # must have something to send a first request to without building anything.
  #
  # Guarded on the *transition* rather than on the agent's existence, so that
  # re-running a verification route on an already-verified account — the
  # release task, a second click on the emailed link — cannot resurrect an
  # agent the tenant deleted. `Starter.create_for/2` is idempotent by name on
  # top of that, which covers two doors finishing the same verification at once.
  #
  # Best-effort by rescuing, exactly like the credit: no failure to make an
  # agent is worth refusing someone their account.
  defp plant_starter_agent(%User{} = user, true) do
    Fountain.Agents.Starter.create_for(user.id)
    :ok
  rescue
    e -> Logger.warning("starter agent for #{user.id} failed: #{inspect(e)}")
  end

  defp plant_starter_agent(_user, _first_verification?), do: :ok

  @doc """
  PubSub topic carrying a user's verification transition.

  `FountainWeb.VerifyPendingLive` subscribes to it so the waiting page in one
  tab advances the moment the emailed link is clicked in another (#533).
  """
  def verification_topic(user_id), do: "user_verification:#{user_id}"

  # After the first-admin bootstrap, so a subscriber that re-reads the user
  # sees the settled role and not a half-applied verification.
  #
  # Skipped when `Fountain.PubSub` is not running (#609). `verify_email/2` is
  # shared with `Fountain.Release.verify_email/1`, whose VM starts the Repo
  # and nothing else — deliberately, since an eval task that booted the whole
  # app would fight the running server for the metrics port and the Horde
  # registry (#256). There, `Registry.meta/2` raised `unknown registry`
  # *after* the row was written and the first-admin bootstrap had run, so the
  # task exited non-zero having already done the work.
  #
  # A guard rather than an opt-out flag: the point of putting verification in
  # the context was that every route behaves the same, and "tell anyone
  # listening" is honestly satisfied by doing nothing when nobody can be. If
  # PubSub is down in the web VM the waiting page is the least of it.
  defp broadcast_verification(%User{} = user) do
    if Process.whereis(Fountain.PubSub) do
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        verification_topic(user.id),
        {:email_verified, user.id}
      )
    end

    :ok
  end

  # Advisory lock key for the first-admin bootstrap. Any stable bigint works;
  # it only has to be distinct from other advisory locks this app takes.
  @first_admin_lock 0xF057AD

  defp maybe_bootstrap_first_admin(%User{role: "admin"} = user), do: user

  defp maybe_bootstrap_first_admin(%User{} = user) do
    if Application.get_env(:fountain, :first_user_admin, false) do
      bootstrap_first_admin(user)
    else
      user
    end
  end

  # Promotion is best-effort on the same terms as audit logging: the account
  # is already verified, and failing that with a bootstrap error would read as
  # a broken signup. The advisory xact lock serializes concurrent first
  # verifications so exactly one can see "no admin exists".
  defp bootstrap_first_admin(%User{} = user) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@first_admin_lock])

      if Repo.exists?(from(u in User, where: u.role == "admin")) do
        user
      else
        case update_user_role(user, "admin") do
          {:ok, promoted} ->
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

          {:error, changeset} ->
            Logger.error("first_user_admin: promotion failed: #{inspect(changeset.errors)}")
            user
        end
      end
    end)
    |> case do
      {:ok, user} ->
        user

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
  - `{:error, :suspended}` — password verified but the account is suspended
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :not_found | :wrong_password | :suspended}
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

        # Password first, deliberately: a wrong guess against a suspended
        # account answers "wrong password", so login responses never become
        # an account-state oracle for someone probing addresses.
        suspended?(user) ->
          {:error, :suspended}

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

  # ── credential management (#448) ─────────────────────────────────────────

  @email_change_salt "email_change"
  @email_change_max_age 86_400

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
  Start a verified email change (#448): the address only changes when a link
  sent to the NEW address is clicked (`apply_email_change/1`).

  Requires the current password — same session-theft reasoning as
  `change_password/3`, and doubly so here because controlling the address
  controls password recovery. Whether the new address is free is never
  revealed: the confirmation is enqueued only when it is, and the caller
  shows the same response either way.
  """
  @spec request_email_change(User.t(), String.t(), String.t()) ::
          :ok | {:error, :no_password | :invalid_current_password | :invalid_email | :same_email}
  def request_email_change(%User{password_hash: nil}, _new_email, _current),
    do: {:error, :no_password}

  def request_email_change(%User{} = user, new_email, current) when is_binary(current) do
    new_email = new_email |> to_string() |> String.trim() |> String.downcase()

    cond do
      not Bcrypt.verify_pass(current, user.password_hash) ->
        {:error, :invalid_current_password}

      not (new_email =~ ~r/^[^\s@]+@[^\s@]+$/) ->
        {:error, :invalid_email}

      new_email == user.email ->
        {:error, :same_email}

      true ->
        if is_nil(get_user_by_email(new_email)) do
          Fountain.Workers.EmailChangeEmail.enqueue_confirmation(user, new_email)
        end

        :ok
    end
  end

  @doc """
  Token for the email-change confirmation link. Carries the target address and
  the `session_version` it was issued against, so a password change (or
  suspension, or a completed change) in the meantime invalidates it.
  """
  @spec email_change_token(User.t(), String.t()) :: String.t()
  def email_change_token(%User{} = user, new_email) do
    Phoenix.Token.sign(
      FountainWeb.Endpoint,
      @email_change_salt,
      {user.id, new_email, user.session_version}
    )
  end

  @doc """
  Complete an email change from a confirmation token.

  Clicking the link is proof of control of the new address, so
  `email_verified_at` is stamped fresh. `session_version` bumps — the change
  is security-relevant and every outstanding session (and any other
  outstanding email-change token) must die with it. The old address is
  notified after the write.

  Returns `{:ok, user, old_email}`, or `{:error, :expired | :invalid |
  :email_taken}`.
  """
  @spec apply_email_change(String.t()) ::
          {:ok, User.t(), String.t()} | {:error, :expired | :invalid | :email_taken}
  def apply_email_change(token) when is_binary(token) do
    with {:ok, {user_id, new_email, session_version}} <-
           Phoenix.Token.verify(FountainWeb.Endpoint, @email_change_salt, token,
             max_age: @email_change_max_age
           ),
         %User{session_version: ^session_version} = user <- get_user(user_id) do
      old_email = user.email
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        user
        |> Ecto.Changeset.change(email: new_email, email_verified_at: now)
        |> Ecto.Changeset.unique_constraint(:email)
        |> User.invalidate_sessions_changeset()
        |> Repo.update()

      case result do
        {:ok, updated} ->
          Fountain.Workers.EmailChangeEmail.enqueue_notice(old_email, new_email)
          {:ok, updated, old_email}

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :email),
            do: {:error, :email_taken},
            else: {:error, :invalid}
      end
    else
      {:error, :expired} -> {:error, :expired}
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Mark onboarding as completed by setting `onboarding_completed_at` to now.

  `onboarding_completed_at` is the whole of it since #1393. The wizard's
  `onboarding_state` column is gone, and so is `advance_onboarding/2`, which
  existed only to walk that state machine: a stamp is either set or it is not,
  and there are no steps left to be part-way through.
  """
  @spec complete_onboarding(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def complete_onboarding(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(onboarding_completed_at: now)
    |> Repo.update()
  end

  @doc """
  Find or create a user from an OAuth provider callback.

  Looks up by `(provider, provider_uid)` first; falls back to email lookup
  to link an existing account. Creates a new user if neither matches.

  For new users: skips email verification (provider-verified email is trusted),
  creates a `UserDataKey`, and creates an `OauthIdentity` row.

  For existing users: upserts the `OauthIdentity` row (safe to call on
  every login).

  A brand-new identity passes the same registration gate as the forms;
  `attrs` may carry the `"access_code"` the person entered before leaving for
  the provider. A returning or linked identity never needs one.

  Returns `{:ok, user, :new | :existing}` or `{:error, changeset}`.
  """
  # The error can also be a registration_allowed?/1 atom: a brand-new OAuth
  # identity on a closed instance rolls the transaction back with it. The spec
  # used to omit the atoms, which made dialyzer condemn the controller branch
  # that handles them as unreachable — it is not.
  @spec upsert_oauth_user(String.t(), String.t(), map()) ::
          {:ok, User.t(), :new | :existing}
          | {:error,
             Ecto.Changeset.t()
             | :registration_closed
             | :email_domain_not_allowed
             | :access_code_required}
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
              case registration_allowed?(email, attrs[:access_code] || attrs["access_code"]) do
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
                # OAuth stamps email_verified_at at insert rather than going
                # through verify_email/1, so the first-admin bootstrap (ADR
                # 0011) needs its own hook here.
                {:ok, maybe_bootstrap_first_admin(user), :new}
              else
                {:error, cs} -> Repo.rollback(cs)
              end
          end
      end
    end)
    |> case do
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
    * `:expires_at` — required for principal scope; other scopes default to no expiry
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

  @doc "Build a key changeset and plaintext without persistence; transactional callers audit after commit."
  def build_api_key(user_id, name, opts \\ []) do
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
  Authenticate a raw API key string.

  Hashes the raw key with SHA-256, queries `api_keys` for a matching row, and
  returns the associated user when the key is active.

  Returns `{:ok, user}` for an active match, `{:error, :revoked}` when the hash
  matches a row whose `revoked_at` is set, and `{:error, :not_found}` when no
  row matches. Callers (e.g. the auth plug) can distinguish these to give
  legitimate clients holding a stale token a more useful error than a generic
  401.
  """
  @spec get_user_by_api_key(String.t()) ::
          {:ok, User.t()} | {:error, :revoked | :expired | :suspended | :unverified | :not_found}
  def get_user_by_api_key(raw_key) when is_binary(raw_key) do
    case authenticate_api_key(raw_key) do
      {:ok, user, _key} -> {:ok, user}
      {:error, _} = err -> err
    end
  end

  @doc """
  Authenticate a raw API key and return the key record alongside the user.

  The auth plug needs the record, not just the user: scope is carried on the key,
  so a caller holding a sandbox token is otherwise indistinguishable from the
  human who owns the tenant.

  Returns `{:ok, user, api_key}`, or
  `{:error, :revoked | :expired | :suspended | :unverified | :not_found}`.
  """
  @spec authenticate_api_key(String.t()) ::
          {:ok, User.t(), ApiKey.t()}
          | {:error, :revoked | :expired | :suspended | :unverified | :not_found}
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

          suspended?(key.user) ->
            {:error, :suspended}

          # Asserted here rather than only where keys are minted (#533). Every
          # minting path already refuses an unverified account, so this changes
          # nothing for a key issued today — but that made four call sites the
          # invariant depended on, and a fifth would have reopened the gap in
          # silence. Keys predating #314, when `POST /api/auth/token` would mint
          # for an unverified account, stop working here: that is the point.
          #
          # A claimable principal (ADR 0044) is the one row that authenticates
          # without ever verifying: it has no email to verify and never will.
          # The flag is read off the already-preloaded user rather than from
          # `claimable_users`, because this is the hottest auth path in the
          # system and a join here would be paid by every request.
          is_nil(key.user.email_verified_at) and not key.user.principal ->
            {:error, :unverified}

          true ->
            {:ok, key.user, key}
        end
    end
  end

  @doc """
  Update `last_used_at` for the API key matching `raw_key`.

  Called from an unlinked task under `Fountain.TaskSupervisor` (see
  `FountainWeb.Plugs.TenantAPIAuth`) so it does not block the request, and
  best-effort *by rescuing*, the position `Audit.record/1` takes for the same
  reason: a failed stamp on a column nothing reads on the hot path is a log
  line, never the reason an already-authenticated request fails (#1040).

  Always returns `:ok`.
  """
  @spec touch_api_key(String.t()) :: :ok
  def touch_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(k in ApiKey, where: k.key_hash == ^key_hash)
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  rescue
    e ->
      Logger.warning("touch_api_key: last_used_at stamp failed: #{inspect(e)}")
      :ok
  end

  ## Internal helpers

  defp insert_user(attrs, kind \\ :password)

  defp insert_user(attrs, :password) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  defp insert_user(attrs, :oauth) do
    %User{}
    |> User.oauth_registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Insert a claimable principal's `users` row (ADR 0044).

  An identity-less tenant: no email, no password, `principal: true`, and its
  own wrapped DEK so that environment and vault secrets encrypt exactly as
  they do for an ordinary account. `Fountain.Principals` owns the grant that
  makes it temporary; this only makes the tenant.

  `:sandbox_limit_override` is the principal's live-sandbox cap and is always
  set by the caller — which is why `Fountain.Quotas` needs no knowledge of
  principals at all: the override branch answers before the balance rule is
  ever consulted.

  Deliberately not audited here. A principal's creation is recorded once, as
  `claimable_user.created` against the application that opened it; a second
  `account.registered` under the principal's own id would be a trail nobody
  can reach, on a tenant with no human behind it.

  Returns `{:ok, user}` or `{:error, changeset}`. Runs in a transaction: a row
  without a data key cannot hold a secret, so the two land together or not
  at all.
  """
  @spec create_principal_user(keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_principal_user(opts \\ []) do
    attrs = %{sandbox_limit_override: Keyword.get(opts, :sandbox_limit_override)}

    Repo.transaction(fn ->
      with {:ok, user} <- %User{} |> User.principal_changeset(attrs) |> Repo.insert(),
           {:ok, _udk} <- create_user_data_key(user.id) do
        user
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
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

  @doc "Active keys the account manages: its own keys and its claimed principals' credentials."
  def list_managed_api_keys(user_id) when is_binary(user_id) do
    user_id
    |> managed_api_keys()
    |> where([k], is_nil(k.revoked_at))
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  @doc "Revoke an owned or claimed-principal credential, with a trail the managing owner can read."
  def revoke_managed_api_key(user_id, key_id, opts \\ []) do
    case user_id |> managed_api_keys() |> where([k], k.id == ^key_id) |> Repo.one() do
      nil ->
        {:error, :not_found}

      key ->
        with {:ok, revoked} <- revoke_api_key(key.user_id, key.id, opts) do
          if key.user_id != user_id do
            Audit.record(%{
              user_id: user_id,
              action: "api_key.revoked",
              resource_type: "api_key",
              resource_id: key.id,
              actor: Keyword.get(opts, :actor, "self"),
              request_ip: Keyword.get(opts, :request_ip),
              metadata: %{
                "name" => key.name,
                "key_prefix" => key.key_prefix,
                "principal_user_id" => key.user_id
              }
            })
          end

          {:ok, revoked}
        end
    end
  end

  defp managed_api_keys(user_id) do
    principals =
      from o in Fountain.Principals.Owner,
        where: o.owner_user_id == ^user_id,
        select: o.principal_user_id

    from k in ApiKey,
      where:
        k.user_id == ^user_id or
          ("principal" in k.scopes and k.user_id in subquery(principals))
  end

  @doc "List all users, ordered by insertion date."
  def list_users do
    from(u in User, order_by: [asc: u.inserted_at]) |> Repo.all()
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
  - `:comped` — `true` for free accounts
  - `:role` — `"admin"` or `"user"`
  - `:verified` — `true`/`false` (whether `email_verified_at` is set)
  - `:sort` — `"email"`, `"joined"`, or `"last_activity"`
    (unknown values fall back to `"joined"`)
  - `:dir` — `"asc"` or `"desc"` (default `"desc"`)
  - `:page` / `:per_page` — 1-based offset pagination

  Returns `%{users: users, total: filtered_count}`. Each user carries a
  `:last_activity_at` key (latest usage event, `nil` if none) — sorting by it
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

      {:comped, comped}, q when is_boolean(comped) ->
        where(q, [u], u.comped == ^comped)

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
    from(e in Fountain.Billing.UsageEvent,
      group_by: e.user_id,
      select: %{user_id: e.user_id, last_at: max(e.inserted_at)}
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

  @doc """
  Override a user's concurrent-sandbox cap (ADR 0005). Admin-only.

  The cap normally follows the credit balance (`Fountain.Quotas.sandbox_limit/1`,
  ADR 0031). This is the operator's override for the two things the balance
  rule cannot express: raising the cap for a trusted tenant, and dropping it
  to zero during abuse. `nil` clears the override and hands the cap back to
  the balance.
  """
  def update_sandbox_limit(%User{} = user, limit, opts \\ []) do
    user
    |> User.sandbox_limit_changeset(%{sandbox_limit_override: limit})
    |> Repo.update()
    |> audited_account("account.sandbox_limit_changed", "user", opts, fn updated ->
      %{"from" => user.sandbox_limit_override, "to" => updated.sandbox_limit_override}
    end)
  end

  @doc """
  Set the operator-owned per-turn execution ceilings for an account.

  `User.execution_limits_changeset/2` has existed since the admission campaign
  with nothing but tests calling it, which meant the only way to give an account
  a ceiling was to write the column by hand. These ceilings are operator-owned
  like the sandbox-cap setter above — no tenant profile or registration path
  accepts these fields — but unlike that one there is no admin control for them
  yet: this function has no caller outside its own test, and the `/admin/users`
  surface beside the sandbox cap arrives with the PR that first enforces a
  control. The audit row records the whole policy before and after, which is an
  operator-set value rather than tenant data. `nil` clears the ceiling.
  """
  def update_execution_limits(%User{} = user, limits, opts \\ []) do
    user
    |> User.execution_limits_changeset(limits)
    |> Repo.update()
    |> audited_account("account.execution_limits_changed", "user", opts, fn updated ->
      %{"from" => user.execution_limits, "to" => updated.execution_limits}
    end)
  end

  @doc false
  def hash_key(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end

  ## Suspension (#287)

  @doc """
  Suspend an account: the reversible abuse lever between comp and delete.
  Deletion is irreversible and destroys evidence; a zeroed sandbox quota stops
  new sandboxes but not logins or running conversations. This stops everything,
  reversibly.

  Sets `suspended_at`, bumps `session_version` (existing sessions die at the
  next request), then best-effort reaps every active sandbox — a failed sprite
  termination logs and moves on rather than failing the suspend; `SandboxReaper`
  sweeps stragglers. Login and API-key auth refuse while `suspended_at` is set.

  Billing is deliberately untouched: the credit ledger keeps its balance and
  the pricer keeps burning whatever was already running (like comped,
  inverted — the balance is accurate, the gate is elsewhere). A suspension is
  short-lived or becomes a deletion.

  Returns `{:ok, user, reaped_count}`.
  """
  @spec suspend_user(User.t(), keyword()) ::
          {:ok, User.t(), non_neg_integer()} | {:error, Ecto.Changeset.t()}
  def suspend_user(%User{} = user, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with {:ok, updated} <-
           user
           |> Ecto.Changeset.change(suspended_at: now)
           |> User.invalidate_sessions_changeset()
           |> Repo.update() do
      # Ownership: admin/system suspension flow — the %User{} being acted on
      # IS the tenant whose sandboxes are reaped; there is no requesting user
      # to scope by.
      reaped = Termination.reap_all_for_user(user.id)

      # Best-effort notification (#450): before this the user's only signal
      # was "account currently unavailable" at their next login attempt. The
      # worker re-checks state and verification at send time.
      Fountain.Workers.AccountEmail.enqueue_suspended(updated)

      record_account_event(updated, "account.suspended", "user", opts, %{
        "sandboxes_reaped" => reaped
      })

      {:ok, updated, reaped}
    end
  end

  @doc """
  Lift a suspension. Sessions stay invalidated (the user logs in again);
  nothing is re-provisioned.
  """
  @spec unsuspend_user(User.t(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def unsuspend_user(%User{} = user, opts \\ []) do
    with {:ok, updated} <- user |> Ecto.Changeset.change(suspended_at: nil) |> Repo.update() do
      Fountain.Workers.AccountEmail.enqueue_unsuspended(updated)
      record_account_event(updated, "account.unsuspended", "user", opts, %{})
      {:ok, updated}
    end
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

  @doc "Whether the account is currently suspended."
  @spec suspended?(User.t()) :: boolean()
  def suspended?(%User{suspended_at: suspended_at}), do: not is_nil(suspended_at)

  @doc """
  Provisioning-path backstop, shaped like `Billing.check_spend/1`: sessions
  and API keys already refuse suspended accounts, but every route to a sprite
  should fail even if a surface slips. An unknown id fails closed.
  """
  @spec check_not_suspended(binary()) :: :ok | {:error, :account_suspended}
  def check_not_suspended(user_id) when is_binary(user_id) do
    case Repo.one(from u in User, where: u.id == ^user_id, select: is_nil(u.suspended_at)) do
      true -> :ok
      _ -> {:error, :account_suspended}
    end
  end
end
