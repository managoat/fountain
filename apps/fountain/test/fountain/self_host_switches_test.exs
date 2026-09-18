defmodule Fountain.SelfHostSwitchesTest do
  @moduledoc """
  The two switches a self-hoster needs and did not have.

  ADR 0006 made the subscription gate a product invariant, which is right for
  the hosted instance and is a lock with no key on a self-hosted one — the ADR
  itself notes the reversal costs "one line", but that line was a source patch.

  Registration was open to the world with no way to close it. On the hosted side
  that matters too: every signup consumes the platform Sprites token, and
  production took 188 signups in two weeks with a 1% activation rate.
  """

  use Fountain.DataCase, async: false

  alias Fountain.{Accounts, Billing}
  alias Fountain.Conversations.Launch

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  # The minimum a :prod evaluation of runtime.exs demands (the same set
  # otel_config_test.exs uses).
  @required_release_env %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "RESEND_API_KEY" => "re_test_key",
    "EMAIL_FROM" => "noreply@fountain.example.com",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  @switch_vars ~w(CREDITS_ENABLED BILLING_ENABLED REGISTRATION_ENABLED REGISTRATION_ALLOWED_EMAIL_DOMAINS REGISTRATION_ACCESS_CODE STRIPE_WEBHOOK_SECRET EMAIL_DELIVERY FIRST_USER_ADMIN)

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

  # An account that cannot spend: the opening credit burned away.
  defp cancelled_user do
    user = insert_verified_user()

    {:ok, _} =
      Fountain.Credits.debit(user.id, Fountain.Credits.balance(user.id) + 1, "burn_turn",
        idempotency_key: "drain-#{user.id}"
      )

    Fountain.Repo.reload!(user)
  end

  describe "the env-var side, read the way the release config provider does" do
    # runtime.exs skips the CREDITS_ENABLED mapping under :test (the suite
    # pins :credits_enabled in config/test.exs), and the domain-list tests
    # below inject the parsed application env directly — so without these,
    # nothing fails if the runtime.exs default flips or the parsing breaks.

    test "CREDITS_ENABLED defaults off — a bare self-host must not lock itself out (#336)" do
      cfg = read_prod_config(%{})
      assert cfg[:fountain][:credits_enabled] == false
    end

    test "CREDITS_ENABLED=true opts the hosted deployment in" do
      # Credits on requires the webhook secret at boot (#416), so supply one.
      cfg =
        read_prod_config(%{
          "CREDITS_ENABLED" => "true",
          "STRIPE_WEBHOOK_SECRET" => "whsec_test"
        })

      assert cfg[:fountain][:credits_enabled] == true
    end

    test "BILLING_ENABLED no longer enables credits" do
      cfg = read_prod_config(%{"BILLING_ENABLED" => "true"})
      assert cfg[:fountain][:credits_enabled] == false
    end

    test "CREDITS_ENABLED controls credits when the retired variable is also set" do
      disabled = read_prod_config(%{"CREDITS_ENABLED" => "false", "BILLING_ENABLED" => "true"})
      assert disabled[:fountain][:credits_enabled] == false

      enabled =
        read_prod_config(%{
          "CREDITS_ENABLED" => "true",
          "BILLING_ENABLED" => "false",
          "STRIPE_WEBHOOK_SECRET" => "whsec_test"
        })

      assert enabled[:fountain][:credits_enabled] == true
    end

    test "REGISTRATION_ALLOWED_EMAIL_DOMAINS is split, trimmed and downcased" do
      cfg =
        read_prod_config(%{
          "REGISTRATION_ALLOWED_EMAIL_DOMAINS" => "Example.com, BETA.org ,gamma.io,"
        })

      assert cfg[:fountain][:registration_allowed_email_domains] ==
               ["example.com", "beta.org", "gamma.io"]
    end

    test "unset or empty REGISTRATION_ALLOWED_EMAIL_DOMAINS means no domain filter" do
      assert read_prod_config(%{})[:fountain][:registration_allowed_email_domains] == []

      assert read_prod_config(%{"REGISTRATION_ALLOWED_EMAIL_DOMAINS" => ""})[:fountain][
               :registration_allowed_email_domains
             ] == []
    end

    test "REGISTRATION_ACCESS_CODE is trimmed, and blank means no code" do
      assert read_prod_config(%{"REGISTRATION_ACCESS_CODE" => " trythegoat\n"})[:fountain][
               :registration_access_code
             ] == "trythegoat"

      assert read_prod_config(%{})[:fountain][:registration_access_code] == nil

      assert read_prod_config(%{"REGISTRATION_ACCESS_CODE" => "  "})[:fountain][
               :registration_access_code
             ] == nil
    end

    test "EMAIL_DELIVERY=none turns :email_enabled off (ADR 0011)" do
      # The blank RESEND_API_KEY matters: compose delivers present-but-empty
      # vars, and "" must not select the Resend adapter over the opt-out (#396).
      {cfg, _stderr} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          read_prod_config(%{"RESEND_API_KEY" => "", "EMAIL_DELIVERY" => "none"})
        end)

      assert cfg[:fountain][:email_enabled] == false
    end

    test "a configured mailer leaves :email_enabled at its default (true)" do
      # runtime.exs must not touch the flag on the happy path — config.exs
      # owns the default.
      cfg = read_prod_config(%{})
      assert cfg[:fountain][:email_enabled] == nil
    end

    test "FIRST_USER_ADMIN defaults off — nobody gets admin for registering first" do
      assert read_prod_config(%{})[:fountain][:first_user_admin] == false
    end

    test "FIRST_USER_ADMIN=true opts a self-host in" do
      assert read_prod_config(%{"FIRST_USER_ADMIN" => "true"})[:fountain][:first_user_admin] ==
               true
    end

    test "REGISTRATION_ENABLED=false closes signup at the config level" do
      assert read_prod_config(%{"REGISTRATION_ENABLED" => "false"})[:fountain][
               :registration_enabled
             ] == false

      assert read_prod_config(%{})[:fountain][:registration_enabled] == true
    end
  end

  describe "CREDITS_ENABLED" do
    test "the gate is enforced by default" do
      assert {:error, :insufficient_credits} = Billing.check_spend(cancelled_user())
    end

    test "disabling it lets a cancelled account through" do
      user = cancelled_user()

      with_env([credits_enabled: false], fn ->
        assert :ok = Billing.check_spend(user)
      end)
    end

    test "a conversation can start with billing disabled" do
      # The end-to-end point: the gate is checked in the context, so the switch
      # has to reach there and not just the controller.
      user = cancelled_user()
      agent = insert_agent(user_id: user.id)

      with_env([credits_enabled: false], fn ->
        stub_server_start(fn _s, _spec ->
          {:ok, spawn(fn -> :ok end)}
        end)

        assert {:ok, _} =
                 Launch.start_conversation(%{
                   "agent_id" => agent.id,
                   "user_id" => user.id
                 })
      end)
    end
  end

  describe "REGISTRATION_ENABLED" do
    test "registration is open by default" do
      assert :ok = Accounts.registration_allowed?("someone@example.com")
    end

    test "closing it refuses new accounts" do
      with_env([registration_enabled: false], fn ->
        assert {:error, :registration_closed} =
                 Accounts.registration_allowed?("someone@example.com")

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

  describe "REGISTRATION_ALLOWED_EMAIL_DOMAINS" do
    test "an empty list allows any domain" do
      assert :ok = Accounts.registration_allowed?("anyone@anywhere.test")
    end

    test "a configured list admits only those domains" do
      with_env([registration_allowed_email_domains: ["example.com"]], fn ->
        assert :ok = Accounts.registration_allowed?("someone@example.com")

        assert {:error, :email_domain_not_allowed} =
                 Accounts.registration_allowed?("someone@elsewhere.com")
      end)
    end

    test "matching is case-insensitive" do
      with_env([registration_allowed_email_domains: ["example.com"]], fn ->
        assert :ok = Accounts.registration_allowed?("Someone@EXAMPLE.com")
      end)
    end

    test "a malformed address is refused rather than admitted" do
      with_env([registration_allowed_email_domains: ["example.com"]], fn ->
        assert {:error, :email_domain_not_allowed} = Accounts.registration_allowed?("no-at-sign")
        assert {:error, :email_domain_not_allowed} = Accounts.registration_allowed?(nil)
      end)
    end
  end

  describe "REGISTRATION_ACCESS_CODE" do
    test "no configured code asks for none" do
      refute Accounts.access_code_required?()
      assert :ok = Accounts.registration_allowed?("someone@example.com")
    end

    test "a configured code refuses a missing or wrong one" do
      with_env([registration_access_code: "trythegoat"], fn ->
        assert Accounts.access_code_required?()

        for code <- [nil, "", "trythegoats", "TRYTHEGOAT"] do
          assert {:error, :access_code_required} =
                   Accounts.registration_allowed?("someone@example.com", code)
        end

        assert {:error, :access_code_required} =
                 Accounts.register_user(%{
                   "email" => "nocode@example.com",
                   "password" => "password123"
                 })

        refute Accounts.get_user_by_email("nocode@example.com")
      end)
    end

    test "the right code, pasted with whitespace, opens registration" do
      with_env([registration_access_code: "trythegoat"], fn ->
        assert :ok = Accounts.registration_allowed?("someone@example.com", " trythegoat ")

        assert {:ok, _user} =
                 Accounts.register_user(%{
                   "email" => "coded@example.com",
                   "password" => "password123",
                   "access_code" => "trythegoat"
                 })
      end)
    end

    test "a closed instance stays closed whatever the code" do
      with_env([registration_enabled: false, registration_access_code: "trythegoat"], fn ->
        assert {:error, :registration_closed} =
                 Accounts.registration_allowed?("someone@example.com", "trythegoat")
      end)
    end

    test "a new OAuth identity needs the code; a returning one does not" do
      user = insert_verified_user()
      uid = "gh-#{System.unique_integer([:positive])}"
      {:ok, _, :existing} = Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})

      with_env([registration_access_code: "trythegoat"], fn ->
        new_uid = "gh-#{System.unique_integer([:positive])}"

        assert {:error, :access_code_required} =
                 Accounts.upsert_oauth_user("github", new_uid, %{"email" => "gh-new@example.com"})

        assert {:ok, _, :new} =
                 Accounts.upsert_oauth_user("github", new_uid, %{
                   "email" => "gh-new@example.com",
                   "access_code" => "trythegoat"
                 })

        assert {:ok, _user, :existing} =
                 Accounts.upsert_oauth_user("github", uid, %{"email" => user.email})
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
