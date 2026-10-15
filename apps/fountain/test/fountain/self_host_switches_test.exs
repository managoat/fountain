defmodule Fountain.SelfHostSwitchesTest do
  @moduledoc """
  The switches a self-hoster needs.

  Registration was open to the world with no way to close it. On the hosted side
  that matters too: every signup consumes the platform Sprites token, and
  production took 188 signups in two weeks with a 1% activation rate.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Accounts

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  # The minimum a :prod evaluation of runtime.exs demands (the same set
  # otel_config_test.exs uses).
  @required_release_env %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "SMTP_HOST" => "smtp.example.com",
    "EMAIL_FROM" => "noreply@fountain.example.com",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  @switch_vars ~w(REGISTRATION_ENABLED REGISTRATION_ALLOWED_EMAIL_DOMAINS REGISTRATION_ACCESS_CODE SMTP_HOST FIRST_USER_ADMIN)

  defp read_prod_config(extra) do
    previous = System.get_env()

    try do
      for k <- @switch_vars, do: System.delete_env(k)

      @required_release_env
      |> Map.put(
        "MASTER_SECRETS_KEY",
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      )
      |> Map.merge(extra)
      |> System.put_env()

      Config.Reader.read!(@runtime_exs, env: :prod)
    after
      System.put_env(previous)
      for k <- @switch_vars, not Map.has_key?(previous, k), do: System.delete_env(k)
    end
  end

  defp with_env(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  describe "the env-var side, read the way the release config provider does" do
    test "no SMTP_HOST turns :email_enabled off (ADR 0011)" do
      # Blank, as compose delivers it (#396), is the same as unset.
      {cfg, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          read_prod_config(%{"SMTP_HOST" => ""})
        end)

      assert cfg[:fountain][:email_enabled] == false
    end

    test "a configured mailer leaves :email_enabled at its default (true)" do
      # runtime.exs must not touch the flag on the happy path — config.exs
      # owns the default.
      cfg = read_prod_config(%{})
      assert cfg[:fountain][:email_enabled] == nil
    end

    test "FIRST_USER_ADMIN is no longer read: the first-admin bootstrap has no switch" do
      for value <- ["true", "false"] do
        cfg = read_prod_config(%{"FIRST_USER_ADMIN" => value})[:fountain]
        refute Keyword.has_key?(cfg, :first_user_admin)
        refute Keyword.has_key?(cfg, :first_admin_bootstrap)
      end
    end

    test "REGISTRATION_ENABLED=false closes signup at the config level" do
      assert read_prod_config(%{"REGISTRATION_ENABLED" => "false"})[:fountain][
               :registration_enabled
             ] == false
    end

    test "REGISTRATION_ENABLED defaults to :auto; only an explicit true opens it for good" do
      # Unset and blank (what compose sends for an absent key) are both the
      # default; "true" is the operator's explicit choice (ADR 0011 addendum).
      for env <- [%{}, %{"REGISTRATION_ENABLED" => ""}, %{"REGISTRATION_ENABLED" => "auto"}] do
        assert read_prod_config(env)[:fountain][:registration_enabled] == :auto
      end

      assert read_prod_config(%{"REGISTRATION_ENABLED" => "true"})[:fountain][
               :registration_enabled
             ] == true
    end

    test "an unrecognised REGISTRATION_ENABLED refuses to boot" do
      assert_raise RuntimeError, ~r/REGISTRATION_ENABLED/, fn ->
        read_prod_config(%{"REGISTRATION_ENABLED" => "yes"})
      end
    end
  end

  defp insert_admin do
    {:ok, admin} = Accounts.update_user_role(insert_verified_user(), "admin")
    admin
  end

  describe "REGISTRATION_ENABLED" do
    test "explicitly true, registration stays open with an admin present" do
      insert_admin()
      assert :ok = Accounts.registration_allowed?()
    end

    test ":auto is open while the instance has never had an admin" do
      insert_verified_user()

      with_env([registration_enabled: :auto], fn ->
        assert Accounts.registration_enabled?()
        assert :ok = Accounts.registration_allowed?()
      end)
    end

    test ":auto closes once an admin exists, on every door" do
      insert_admin()

      with_env([registration_enabled: :auto], fn ->
        refute Accounts.registration_enabled?()

        assert {:error, :registration_closed} =
                 Accounts.register_user(%{
                   "email" => "stranger@example.com",
                   "password" => "password123"
                 })

        assert {:error, :registration_closed} =
                 Accounts.upsert_oauth_user("github", "gh-stranger", %{
                   "email" => "stranger@example.com"
                 })
      end)
    end

    test ":auto stays closed after the last admin is demoted" do
      admin = insert_admin()

      # The grant on the privilege trail is what outlives the role.
      Fountain.Audit.record_admin(%{
        actor_user_id: nil,
        target_user_id: admin.id,
        event_type: "admin.role.granted"
      })

      {:ok, _} = Accounts.update_user_role(admin, "user")

      with_env([registration_enabled: :auto], fn ->
        refute Accounts.registration_enabled?()
      end)
    end

    test ":auto leaves an admin's own door open (ADR 0064)" do
      admin = insert_admin()

      with_env([registration_enabled: :auto], fn ->
        assert {:ok, {_user, _key}} = Accounts.create_account_by_admin(admin, "app@example.com")
      end)
    end

    test "closing it refuses new accounts" do
      with_env([registration_enabled: false], fn ->
        assert {:error, :registration_closed} =
                 Accounts.registration_allowed?()

        assert {:error, :registration_closed} =
                 Accounts.register_user(%{
                   "email" => "blocked@example.com",
                   "password" => "password123"
                 })
      end)
    end

    test "closing it does not affect existing accounts" do
      user = insert_verified_user()

      with_env([registration_enabled: false], fn ->
        assert {:ok, %{id: id}} = Accounts.authenticate_user(user.email, "password123")
        assert id == user.id
      end)
    end
  end

  describe "OAuth signup" do
    test "is gated too, not just the forms" do
      # The path most likely to be missed by a controller-level check: an
      # unrecognised OAuth identity creates an account.
      with_env([registration_enabled: false], fn ->
        assert {:error, :registration_closed} =
                 Accounts.upsert_oauth_user(
                   "github",
                   "gh-#{System.unique_integer([:positive])}",
                   %{
                     "email" => "newcomer@example.com"
                   }
                 )
      end)
    end

    test "an existing user can still sign in when registration is closed" do
      user = insert_verified_user()
      uid = "gh-#{System.unique_integer([:positive])}"
      {:ok, _, :existing} = Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})

      with_env([registration_enabled: false], fn ->
        assert {:ok, _user, :existing} =
                 Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})
      end)
    end
  end
end
