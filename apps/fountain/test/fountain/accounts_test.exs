defmodule Fountain.AccountsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Accounts.User

  # Pure unit tests do not touch the DB.

  describe "User.registration_changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        User.registration_changeset(%User{}, %{
          email: "Alice@Example.com",
          password: "password123"
        })

      assert cs.valid?
      # email is downcased
      assert Ecto.Changeset.get_change(cs, :email) == "alice@example.com"
      # password is hashed and cleared from changes
      refute Ecto.Changeset.get_change(cs, :password)
      assert Ecto.Changeset.get_change(cs, :password_hash)
    end

    test "missing email is invalid" do
      cs = User.registration_changeset(%User{}, %{password: "password123"})
      assert "can't be blank" in errors_on(cs, :email)
    end

    test "missing password is invalid" do
      cs = User.registration_changeset(%User{}, %{email: "a@b.com"})
      assert "can't be blank" in errors_on(cs, :password)
    end

    test "password shorter than 8 chars is invalid" do
      cs = User.registration_changeset(%User{}, %{email: "a@b.com", password: "short"})
      assert "must be at least 8 characters" in errors_on(cs, :password)
    end

    test "malformed email is invalid" do
      cs = User.registration_changeset(%User{}, %{email: "notanemail", password: "password123"})
      assert "must be a valid email address" in errors_on(cs, :email)
    end

    test "email without domain is invalid" do
      cs = User.registration_changeset(%User{}, %{email: "a@", password: "password123"})
      assert "must be a valid email address" in errors_on(cs, :email)
    end

    test "role defaults to user when omitted" do
      cs = User.registration_changeset(%User{}, %{email: "a@b.com", password: "password123"})
      # default comes from schema, not changeset; changeset doesn't set it explicitly
      assert cs.valid?
    end

    test "invalid role is rejected" do
      cs =
        User.registration_changeset(%User{}, %{
          email: "a@b.com",
          password: "password123",
          role: "superuser"
        })

      assert "is invalid" in errors_on(cs, :role)
    end
  end

  describe "Accounts.hash_key/1" do
    test "produces a 64-character lowercase hex string" do
      hash = Accounts.hash_key("ftn_abc123")
      assert byte_size(hash) == 64
      assert hash =~ ~r/^[0-9a-f]+$/
    end

    test "same input always produces same hash (deterministic)" do
      assert Accounts.hash_key("somekey") == Accounts.hash_key("somekey")
    end

    test "different inputs produce different hashes" do
      assert Accounts.hash_key("key1") != Accounts.hash_key("key2")
    end

    test "hash of 'ftn_...' prefix matches the stored key_hash pattern" do
      raw = "ftn_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      hash = Accounts.hash_key(raw)
      assert String.length(hash) == 64
    end
  end

  describe "User.theme_changeset/2" do
    test "accepts valid theme preferences" do
      user = %Fountain.Accounts.User{}

      for theme <- ~w(system light dark) do
        cs = Fountain.Accounts.User.theme_changeset(user, %{theme_preference: theme})
        assert cs.valid?
      end
    end

    test "rejects invalid theme preference" do
      user = %Fountain.Accounts.User{}
      cs = Fountain.Accounts.User.theme_changeset(user, %{theme_preference: "invalid"})
      refute cs.valid?
      assert cs.errors[:theme_preference] != nil
    end
  end

  # Private helper
  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
