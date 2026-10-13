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
    field :role, :string, default: "user"
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
    |> cast(attrs, [:email, :password, :role])
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
    |> cast(attrs, [:email, :role, :email_verified_at])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_inclusion(:role, @roles)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
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
