defmodule FountainWeb.SelfHostBootstrapTest do
  @moduledoc """
  The in-app first-login path for self-hosters (ADR 0011).

  Two switches replace the release-task shenanigans the deploy guides used to
  require: with `EMAIL_DELIVERY=none` registration self-verifies (a
  verification link that can never be delivered gates nothing), and with
  `FIRST_USER_ADMIN=true` the first verified account on an instance with no
  admin is promoted, audit-recorded, on whichever route verified it.

  async: false — these toggle global application env.
  """

  use FountainWeb.ConnCase, async: false
  use Oban.Testing, repo: Fountain.Repo

  import Ecto.Query

  alias Fountain.{Accounts, Repo}
  alias Fountain.Audit.AdminEvent
  alias Fountain.Workers.VerificationEmail

  defp with_env(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp grant_events(user_id) do
    Repo.all(
      from e in AdminEvent,
        where: e.target_user_id == ^user_id and e.event_type == "admin.role.granted"
    )
  end

  describe "registration with email delivery disabled" do
    test "HTML signup self-verifies, skips the email, and points at login", %{conn: conn} do
      conn =
        with_env([email_enabled: false], fn ->
          post(conn, ~p"/auth/register", %{
            "user" => %{"email" => "hoster@example.com", "password" => "password123"}
          })
        end)

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "sign in"

      user = Accounts.get_user_by_email("hoster@example.com")
      assert %DateTime{} = user.email_verified_at
      refute_enqueued(worker: VerificationEmail)

      # The self-verifying door is verification like any other, so it plants
      # the starter agent too (ADR 0038). It is also the only door that runs
      # inside the registration transaction, which is where a planting that
      # rolled back would take the whole account with it.
      assert [%{name: "starter"}] = Fountain.Agents.list_agents(user.id, [])
    end

    test "API signup self-verifies and says so", %{conn: conn} do
      conn =
        with_env([email_enabled: false], fn ->
          post_json(conn, "/api/auth/register", %{
            email: "api-hoster@example.com",
            password: "password123"
          })
        end)

      assert json_response(conn, 201)["message"] =~ "sign in"
      refute json_response(conn, 201)["message"] =~ "email"

      user = Accounts.get_user_by_email("api-hoster@example.com")
      assert %DateTime{} = user.email_verified_at
      refute_enqueued(worker: VerificationEmail)
    end

    test "with email enabled nothing changes: unverified account, email enqueued", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "mailed@example.com", "password" => "password123"}
        })

      assert redirected_to(conn) == ~p"/auth/check-email"

      user = Accounts.get_user_by_email("mailed@example.com")
      assert is_nil(user.email_verified_at)
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end
  end

  describe "FIRST_USER_ADMIN" do
    test "the first verified account is promoted, audit-recorded with a nil actor" do
      user = insert_user()

      {:ok, verified} = with_env([first_user_admin: true], fn -> Accounts.verify_email(user) end)

      assert verified.role == "admin"
      assert [event] = grant_events(verified.id)
      assert is_nil(event.actor_user_id)
      assert event.metadata["via"] == "first_user_admin"
      assert event.metadata["email"] == user.email
    end

    test "the second verified account stays a user" do
      with_env([first_user_admin: true], fn ->
        {:ok, first} = Accounts.verify_email(insert_user())
        {:ok, second} = Accounts.verify_email(insert_user())

        assert first.role == "admin"
        assert second.role == "user"
        assert grant_events(second.id) == []
      end)
    end

    test "registration alone grants nothing — the promotion waits for verification" do
      with_env([first_user_admin: true], fn ->
        user = insert_user()
        assert user.role == "user"
        assert grant_events(user.id) == []
      end)
    end

    test "it never re-arms: a demoted last admin does not hand the instance to the next account" do
      {:ok, first} =
        with_env([first_user_admin: true], fn -> Accounts.verify_email(insert_user()) end)

      assert first.role == "admin"
      {:ok, _} = Accounts.update_user_role(first, "user")
      refute Repo.exists?(from u in Fountain.Accounts.User, where: u.role == "admin")

      {:ok, newcomer} =
        with_env([first_user_admin: true], fn -> Accounts.verify_email(insert_user()) end)

      assert newcomer.role == "user"
      assert grant_events(newcomer.id) == []
    end

    test "it never re-arms after the last admin's account is deleted" do
      {:ok, first} =
        with_env([first_user_admin: true], fn -> Accounts.verify_email(insert_user()) end)

      Repo.delete!(first)

      {:ok, newcomer} =
        with_env([first_user_admin: true], fn -> Accounts.verify_email(insert_user()) end)

      assert newcomer.role == "user"
    end

    test "an instance that already has an admin never bootstraps another" do
      {:ok, _admin} = Accounts.update_user_role(insert_verified_user(), "admin")

      {:ok, verified} =
        with_env([first_user_admin: true], fn -> Accounts.verify_email(insert_user()) end)

      assert verified.role == "user"
      assert grant_events(verified.id) == []
    end

    test "off by default: verification never promotes" do
      {:ok, verified} = Accounts.verify_email(insert_user())

      assert verified.role == "user"
      assert grant_events(verified.id) == []
    end

    test "a brand-new OAuth identity is the first admin too" do
      # OAuth accounts are verified at insert without passing through
      # verify_email/1 — the path most likely to be missed.
      {:ok, user, :new} =
        with_env([first_user_admin: true], fn ->
          Accounts.upsert_oauth_user(
            "github",
            "gh-#{System.unique_integer([:positive])}",
            %{"email" => "oauth-hoster@example.com"}
          )
        end)

      assert user.role == "admin"
      assert [_event] = grant_events(user.id)
    end

    test "both switches together: one registration yields a ready admin" do
      # The whole point of ADR 0011 — nothing left for the deploy to do.
      {:ok, user} =
        with_env([email_enabled: false, first_user_admin: true], fn ->
          Accounts.register_user(%{
            "email" => "founder@example.com",
            "password" => "password123"
          })
        end)

      assert %DateTime{} = user.email_verified_at
      assert user.role == "admin"
      assert [_event] = grant_events(user.id)
    end
  end

  describe "auto-verified registration audits after the commit (ADR 0013)" do
    # Each audit insert is made to fail. Inside the registration transaction
    # a failed insert aborts the transaction and takes the account with it;
    # after the commit it is a logged, best-effort miss.
    test "a failing audit write does not roll back the account, the grant or the starter" do
      Repo.query!("""
      CREATE FUNCTION pg_temp.refuse_audit() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'audit refused'; END $$ LANGUAGE plpgsql
      """)

      for table <- ~w(audit_events admin_audit_events) do
        Repo.query!("""
        CREATE TRIGGER refuse_audit BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_audit()
        """)
      end

      {:ok, user} =
        ExUnit.CaptureLog.with_log(fn ->
          with_env([email_enabled: false, first_user_admin: true], fn ->
            Accounts.register_user(%{
              "email" => "audit-down@example.com",
              "password" => "password123"
            })
          end)
        end)
        |> elem(0)

      reloaded = Accounts.get_user(user.id)
      assert %DateTime{} = reloaded.email_verified_at
      assert reloaded.role == "admin"
      assert [%{name: "starter"}] = Fountain.Agents.list_agents(user.id, [])
    end
  end
end
