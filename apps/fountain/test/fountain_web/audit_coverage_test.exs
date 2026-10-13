defmodule FountainWeb.AuditCoverageTest do
  @moduledoc """
  Audit coverage across the surfaces that had none.

  There was exactly one `Audit.record` call site in the codebase — a plug on the
  `:api` pipeline. So writing a secret through the API produced a record and
  writing the identical secret through the UI produced nothing, which is the
  wrong way round for a product whose job is holding tenant secrets. Login,
  logout, password reset and admin role changes were likewise invisible, and
  `actor` was hardcoded to `"api"`, making a human, a CI job and an agent inside
  a sandbox indistinguishable.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Audit
  alias Fountain.Audit.AdminEvent
  alias Fountain.Repo

  defp events_for(user_id) do
    Audit.list_recent_for_user(user_id, 100)
  end

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  defp created_events(user_id) do
    Enum.filter(events_for(user_id), &(&1.action == "api_key.created"))
  end

  describe "secret writes through the UI" do
    test "a vault secret write is recorded", %{conn: conn} do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/vaults/#{vault.id}/edit")

      lv
      |> element("form[phx-submit='add_secret']")
      |> render_submit(%{"secret" => %{"key" => "API_TOKEN", "value" => "s3cret"}})

      event = find_action(user.id, "vault.secret.write")
      assert event, "writing a vault secret through the UI must be audited"
      assert event.actor == "ui"
      assert event.resource_id == vault.id
      assert event.metadata["key"] == "API_TOKEN"
    end

    test "the secret value is never written to the audit log", %{conn: conn} do
      # The key is the useful part; the value is the thing that must not leak
      # into a second table.
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/vaults/#{vault.id}/edit")

      lv
      |> element("form[phx-submit='add_secret']")
      |> render_submit(%{"secret" => %{"key" => "K", "value" => "super-secret-value"}})

      events = events_for(user.id)

      # Guard the guard: if vault-secret auditing disappeared entirely this
      # list would be empty and the refute below would vacuously pass over
      # nothing (#406). The write above must have produced its record.
      assert Enum.any?(events, &(&1.action == "vault.secret.write"))

      for event <- events do
        refute inspect(event.metadata) =~ "super-secret-value"
      end
    end

    test "an environment secret write is recorded", %{conn: conn} do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/environments/#{env.id}/edit")

      lv
      |> element("form[phx-submit='add_secret']")
      |> render_submit(%{"secret" => %{"key" => "DB_URL", "value" => "postgres://x"}})

      event = find_action(user.id, "environment.secret.write")
      assert event
      assert event.metadata["key"] == "DB_URL"
    end
  end

  describe "secret writes through the API (#530)" do
    setup do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)
      {:ok, user: user, key: key}
    end

    test "an environment secret write and delete are recorded", %{
      conn: conn,
      user: user,
      key: key
    } do
      env = insert_env(user_id: user.id)

      conn
      |> authed_with_key(key)
      |> post_json("/api/environments/#{env.id}/secrets", %{
        "key" => "DB_URL",
        "value" => "pg://x"
      })
      |> json_response(201)

      write = find_action(user.id, "environment.secret.write")
      assert write, "writing a secret through the API must be audited like the UI does"
      assert write.actor == "api"
      assert write.resource_id == env.id
      assert write.metadata["key"] == "DB_URL"

      build_conn()
      |> authed_with_key(key)
      |> delete("/api/environments/#{env.id}/secrets/DB_URL")
      |> response(204)

      delete_event = find_action(user.id, "environment.secret.delete")
      assert delete_event
      assert delete_event.resource_id == env.id
      assert delete_event.metadata["key"] == "DB_URL"
    end

    test "a vault secret write and delete are recorded", %{conn: conn, user: user, key: key} do
      vault = insert_vault(user_id: user.id)

      conn
      |> authed_with_key(key)
      |> post_json("/api/vaults/#{vault.id}/secrets", %{"key" => "TOKEN", "value" => "s3cret"})
      |> json_response(201)

      write = find_action(user.id, "vault.secret.write")
      assert write
      assert write.resource_id == vault.id
      assert write.metadata["key"] == "TOKEN"

      build_conn()
      |> authed_with_key(key)
      |> delete("/api/vaults/#{vault.id}/secrets/TOKEN")
      |> response(204)

      assert find_action(user.id, "vault.secret.delete")
    end

    test "a sprite token's secret write is attributed to the sandbox", %{conn: conn, user: user} do
      # The whole point of the semantic event: "the agent wrote this secret" and
      # "the account owner wrote this secret" must be distinguishable.
      {_rec, sprite_key} = insert_sprite_api_key(user)
      vault = insert_vault(user_id: user.id)

      conn
      |> authed_with_key(sprite_key)
      |> post_json("/api/vaults/#{vault.id}/secrets", %{"key" => "K", "value" => "v"})
      |> json_response(201)

      write = find_action(user.id, "vault.secret.write")
      assert write.actor == "sprite"
    end

    test "the secret value never reaches the audit log", %{conn: conn, user: user, key: key} do
      env = insert_env(user_id: user.id)

      conn
      |> authed_with_key(key)
      |> post_json("/api/environments/#{env.id}/secrets", %{
        "key" => "K",
        "value" => "super-secret-value"
      })
      |> json_response(201)

      events = events_for(user.id)

      # Guard the guard (#406): an empty list would make the refute vacuous.
      assert Enum.any?(events, &(&1.action == "environment.secret.write"))

      for event <- events do
        refute inspect(event.metadata) =~ "super-secret-value"
      end
    end

    test "secrets written by a manifest apply are recorded per key", %{
      conn: conn,
      user: user,
      key: key
    } do
      conn
      |> authed_with_key(key)
      |> post_json("/api/apply", %{
        "resources" => [
          %{
            "kind" => "Environment",
            "name" => "prod",
            "spec" => %{"secrets" => %{"A" => "1", "B" => "2"}}
          },
          %{
            "kind" => "Vault",
            "name" => "creds",
            "spec" => %{"secrets" => %{"C" => "3"}}
          }
        ]
      })
      |> json_response(200)

      env_writes =
        Enum.filter(events_for(user.id), &(&1.action == "environment.secret.write"))

      assert Enum.map(env_writes, & &1.metadata["key"]) |> Enum.sort() == ["A", "B"]
      assert Enum.all?(env_writes, &(&1.metadata["via"] == "apply"))
      assert Enum.all?(env_writes, &(&1.resource_id != nil))

      vault_write = find_action(user.id, "vault.secret.write")
      assert vault_write.metadata["key"] == "C"
    end
  end

  describe "authentication events" do
    test "a successful login is recorded", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password12345"})

      post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "password12345"})

      event = find_action(user.id, "auth.login")
      assert event
      assert event.actor == "ui"
      assert event.metadata["result"] == "ok"
    end

    test "a failed login is recorded, which is the one that matters", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password12345"})

      post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "wrong-password"})

      # Attributed to no tenant, since the attempt failed — visible in the
      # admin view rather than the user's own trail.
      event = Enum.find(Audit._unsafe_list_recent(50), &(&1.action == "auth.login.failed"))
      assert event, "failed logins must leave a record — a run of them is the signal"
      assert event.metadata["email"] == user.email
      refute event.metadata["password"]
    end

    test "a password reset is recorded" do
      user = insert_verified_user()

      token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version}
        )

      build_conn()
      |> post(~p"/auth/reset", %{"token" => token, "password" => "new-password-123"})

      assert find_action(user.id, "auth.password.reset")
    end
  end

  describe "admin actions" do
    setup do
      admin = insert_verified_user()
      {:ok, admin} = Fountain.Accounts.update_user_role(admin, "admin")
      {:ok, admin: admin}
    end

    test "granting the admin role is recorded with actor and target", %{conn: conn, admin: admin} do
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin/users")
      render_click(lv, "toggle_admin", %{"id" => target.id})

      assert [event] = Repo.all(AdminEvent)
      assert event.event_type == "admin.role.granted"
      assert event.actor_user_id == admin.id
      assert event.target_user_id == target.id
      assert event.metadata["to"] == "admin"
    end

    test "revoking the admin role is recorded distinctly", %{conn: conn, admin: admin} do
      target = insert_verified_user()
      {:ok, target} = Fountain.Accounts.update_user_role(target, "admin")

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin/users")
      render_click(lv, "toggle_admin", %{"id" => target.id})

      assert [event] = Repo.all(AdminEvent)
      assert event.event_type == "admin.role.revoked"
    end

    test "the admin view surfaces the trail", %{conn: conn, admin: admin} do
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin/users")
      render_click(lv, "toggle_admin", %{"id" => target.id})

      {:ok, _lv2, html} = live(login_user(conn, admin), ~p"/admin/activity")
      assert html =~ "admin.role.granted"
      assert html =~ target.email
    end
  end

  describe "actor attribution" do
    test "a sprite callback token is distinguished from a human's key", %{conn: conn} do
      # "the agent did this" and "the account owner did this" are very different
      # claims, and were indistinguishable when actor was hardcoded.
      user = insert_verified_user()
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> post_json("/api/environments", %{"name" => "from-a-sandbox"})
      |> json_response(201)

      event = Enum.find(events_for(user.id), &(&1.actor == "sprite"))
      assert event, "a sandbox-originated write must be attributable to the sandbox"
    end

    test "an ordinary API key is recorded as api", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)

      conn
      |> authed_with_key(key)
      |> post_json("/api/environments", %{"name" => "from-cli"})
      |> json_response(201)

      assert Enum.any?(events_for(user.id), &(&1.actor == "api"))
      refute Enum.any?(events_for(user.id), &(&1.actor == "sprite"))
    end
  end

  describe "the AdminEvent allowlist matches the code (#451)" do
    test "every admin.* event type used in lib/ is in the allowlist" do
      # The allowlist is a closed validate_inclusion, and record_admin is
      # best-effort — an event type shipped without being added here is
      # rejected at write time and the privilege trail silently loses the
      # row. That happened twice before #451. This scan turns the mistake
      # into a test failure at development time.
      #
      # The regex catches the dominant call-site shape (a string literal
      # under an event_type: key). Types built dynamically (e.g. the
      # role-grant if/else) are not caught here, but their branches are
      # string literals matched elsewhere in the same expression.
      used =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          ~r/"(admin\.[a-z_]+(?:\.[a-z_]+)+)"/
          |> Regex.scan(File.read!(file))
          |> Enum.map(fn [_, type] -> type end)
        end)
        |> Enum.uniq()

      assert used != [], "expected to find admin.* event types in lib/ — did call sites move?"

      missing = used -- AdminEvent.event_types()

      assert missing == [],
             "admin event types used in code but missing from the AdminEvent allowlist — " <>
               "these writes would be rejected and the trail rows lost: #{inspect(missing)}"
    end
  end

  describe "API key lifecycle through the UI" do
    test "creation and revocation are both recorded", %{conn: conn} do
      user = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/api-keys")
      render_submit(lv, "create_key", %{"label" => "ci-deploy"})

      created = find_action(user.id, "api_key.created")
      assert created
      assert created.metadata["name"] == "ci-deploy"

      key_id = created.resource_id
      render_click(lv, "revoke", %{"id" => key_id})

      assert find_action(user.id, "api_key.revoked")
    end
  end

  describe "API key minting is audited wherever it happens (#542)" do
    test "POST /api/auth/token records the mint", %{conn: conn} do
      # The gap this closes: the route lives on `:api_public`, which has no
      # audit plug, so the one path that trades a password for a full-scope
      # key was the only one of the four that minted with no trail.
      user =
        insert_verified_user(%{
          "email" => "cli#{System.unique_integer([:positive])}@example.com",
          "password" => "password123"
        })

      conn = post_json(conn, "/api/auth/token", %{email: user.email, password: "password123"})
      %{"key_id" => key_id, "prefix" => prefix} = json_response(conn, 201)

      assert [event] = created_events(user.id)
      assert event.user_id == user.id
      assert event.resource_type == "api_key"
      assert event.resource_id == key_id
      assert event.actor == "api"
      assert event.metadata["scopes"] == ["full"]
      assert event.metadata["key_prefix"] == prefix
    end

    test "POST /api/auth/token never records the key itself", %{conn: conn} do
      user =
        insert_verified_user(%{
          "email" => "cli#{System.unique_integer([:positive])}@example.com",
          "password" => "password123"
        })

      conn = post_json(conn, "/api/auth/token", %{email: user.email, password: "password123"})
      %{"api_key" => raw_key} = json_response(conn, 201)

      events = events_for(user.id)

      # Guard the guard (#406): with no mint event at all the refute below
      # would pass over an empty list and prove nothing.
      assert Enum.any?(events, &(&1.action == "api_key.created"))

      # The 8-character prefix is in the trail by design; the other 64
      # characters are the credential and must not follow it into a second
      # table.
      for event <- events do
        refute inspect(event) =~ raw_key
      end
    end

    test "a rejected credential mints nothing and records nothing", %{conn: conn} do
      user =
        insert_verified_user(%{
          "email" => "cli#{System.unique_integer([:positive])}@example.com",
          "password" => "password123"
        })

      conn = post_json(conn, "/api/auth/token", %{email: user.email, password: "wrongpassword"})
      assert json_response(conn, 401)

      assert created_events(user.id) == []
    end

    test "POST /api/auth/api-keys records a semantic event, not just the request", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user, "bootstrap")

      # The factory mints through the same context function, so the bootstrap
      # key is itself audited — this asserts on the one the request adds.
      before = created_events(user.id)

      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/auth/api-keys", %{name: "CI pipeline"})
      |> json_response(201)

      assert [event] = created_events(user.id) -- before
      assert event.actor == "api"
      assert event.metadata["name"] == "CI pipeline"
    end

    test "one mint through the UI writes one row, not two", %{conn: conn} do
      # `create_api_key/3` audits itself now; the LiveView's own `from_socket`
      # call had to go with it or every UI mint would land twice.
      user = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/api-keys")
      render_submit(lv, "create_key", %{"label" => "ci-deploy"})

      assert [event] = created_events(user.id)
      assert event.actor == "ui"
      assert event.request_ip
    end

    test "a sprite callback key is attributed to the server, not the owner" do
      user = insert_verified_user()

      {:ok, {key, _raw}} =
        Fountain.Accounts.create_api_key(
          user.id,
          "sprite:abc123",
          Fountain.Conversations.ConversationServer.callback_api_key_opts()
        )

      assert [event] = created_events(user.id)
      assert event.resource_id == key.id
      assert event.actor == "system:conversation_server"
      assert event.metadata["scopes"] == ["sprite"]
    end
  end
end
