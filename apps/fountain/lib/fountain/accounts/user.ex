defmodule Fountain.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(user admin)
  @theme_values ~w(light dark system)

  @type t :: %__MODULE__{}
  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :email_verified_at, :utc_datetime
    field :onboarding_completed_at, :utc_datetime
    # Per-user override of the balance-funded concurrent-sandbox cap
    # (`Fountain.Quotas.sandbox_limit/1`); null means the balance rule. The
    # Postgres column is still `max_concurrent_sandboxes` — renaming it would
    # break a rolling deploy — so the honest name lives here.
    field :sandbox_limit_override, :integer, source: :max_concurrent_sandboxes
    # Cached sum of `credit_ledger` (ADR 0030). Written only by
    # `Fountain.Credits`, in the same transaction as the ledger row; never
    # cast from user input.
    field :credit_balance_cents, :integer, default: 0
    # Operator-owned per-turn ceilings, read by launch preflight. Later-turn and
    # recovery ceiling checks remain unwired; leave overrides empty until integrated.
    # Never cast it through registration, OAuth or profile changes.
    field :execution_limits, :map, default: %{}
    field :role, :string, default: "user"
    field :stripe_customer_id, :string
    # A free account (ADR 0031): the balance is never checked. Set only from
    # the admin panel; the one operator lever.
    field :comped, :boolean, default: false
    # Set by an operator; a suspended account cannot sign in or spend.
    field :suspended_at, :utc_datetime
    # Bumped to invalidate every session (password change, suspension).
    field :session_version, :integer, default: 0
    field :theme_preference, :string, default: "system"
    field :conversations_roots_only, :boolean, default: false
    field :conversation_visible_streams, {:array, :string}, default: ["stdout", "stderr", "stage"]
    field :conversation_view_mode, :string, default: "pretty"

    has_many :api_keys, Fountain.Accounts.ApiKey
    has_one :data_key, Fountain.Accounts.UserDataKey
    has_many :oauth_identities, Fountain.Accounts.OauthIdentity

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  @doc "Changeset for new user registration (email + password path)."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :role, :sandbox_limit_override])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_inclusion(:role, @roles)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
    |> hash_password()
  end

  @doc """
  Changeset for an account an admin opens over the API (ADR 0064): a platform
  built on this instance opening one per application.

  No password, so nobody signs in as it: the platform holds its API key.
  Verified at creation, because the address is the operator's own naming and
  no mail is read there. The role is never cast; it is always `user`.
  """
  def admin_created_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
    |> put_change(:email_verified_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc "Changeset for OAuth registration (no password required; email pre-verified by provider)."
  def oauth_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :role, :sandbox_limit_override, :email_verified_at])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_inclusion(:role, @roles)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end

  @doc """
  Changeset for the per-tenant sandbox concurrency override (ADR 0005).

  Admin-only. Zero is valid and meaningful — it is the lever for cutting off an
  abusive tenant without deleting their account. `nil` is valid too and means
  something different: clear the override and let the balance decide again.
  """
  def sandbox_limit_changeset(user, attrs) do
    user
    |> cast(attrs, [:sandbox_limit_override])
    |> validate_number(:sandbox_limit_override, greater_than_or_equal_to: 0)
  end

  @doc """
  Validate operator-owned execution ceiling storage; nil clears the override.

  This primitive does not authorize an operator or enforce a ceiling. A future
  context must establish operator authority and audit writes before exposing it.
  """
  def execution_limits_changeset(user, limits) do
    case Fountain.Conversations.ExecutionLimits.normalize(limits) do
      {:ok, normalized} ->
        change(user, execution_limits: normalized)

      {:error, {:execution_limits_invalid, field}} ->
        user |> change() |> add_error(:execution_limits, "invalid #{field}")
    end
  end

  @doc "Changeset for the Stripe customer id, written when a Checkout is opened."
  def billing_changeset(user, attrs) do
    user
    |> cast(attrs, [:stripe_customer_id])
    |> unique_constraint(:stripe_customer_id)
  end

  @doc "Admin-only: the comp flag (ADR 0031)."
  def comp_changeset(user, attrs) do
    user |> cast(attrs, [:comped]) |> validate_required([:comped])
  end

  @doc "Changeset for updating theme preference (light | dark | system)."
  def theme_changeset(user, attrs) do
    user
    |> cast(attrs, [:theme_preference])
    |> validate_inclusion(:theme_preference, @theme_values)
  end

  @doc "Changeset for resetting a password (validates + hashes new password)."
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  @doc "Changeset for bumping session_version (e.g. on password reset). Accepts a User struct or an existing changeset."
  def invalidate_sessions_changeset(%Ecto.Changeset{data: %__MODULE__{} = user} = changeset) do
    put_change(changeset, :session_version, (user.session_version || 0) + 1)
  end

  def invalidate_sessions_changeset(%__MODULE__{} = user) do
    user
    |> change()
    |> put_change(:session_version, (user.session_version || 0) + 1)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
