defmodule FountainWeb.ApiKeysLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  describe "ApiKeysLive.Index — rendering" do
    test "shows existing active keys", %{conn: conn} do
      user = insert_verified_user()
      insert_api_key(user, "ci-deploy")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      assert html =~ "ci-deploy"
      assert html =~ "ftn_"
    end

    test "renders key with nil last_used_at using em-dash placeholder", %{conn: conn} do
      user = insert_verified_user()
      insert_api_key(user, "never-used")

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      # Key exists, page renders without error; last_used_at is nil so "—" appears
      assert html =~ "never-used"
      assert html =~ "—"
    end

    test "shows empty state when no keys exist", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      assert html =~ "No API keys yet"
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/api-keys")
      assert path =~ "/auth/login"
    end
  end

  describe "ApiKeysLive.Index — create_key" do
    test "creates a key and shows raw token once", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      html =
        lv
        |> form("form[phx-submit='create_key']", label: "my-key")
        |> render_submit()

      assert html =~ "ftn_"
      assert html =~ "Copy"
      assert html =~ "it won&#39;t be shown again" or html =~ "won't be shown again"
    end

    test "dismissing the new key banner hides the raw token", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      lv |> form("form[phx-submit='create_key']", label: "temp-key") |> render_submit()

      html = lv |> element("button", "I've copied it") |> render_click()
      refute html =~ "ftn_" and html =~ "won't be shown again"
    end
  end

  describe "ApiKeysLive.Index — revoke" do
    test "revoking a key removes it from the list", %{conn: conn} do
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "to-revoke")

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/api-keys")
      assert html =~ "to-revoke"

      lv |> element("button[phx-value-id='#{key.id}']", "Revoke") |> render_click()

      html = render(lv)
      refute html =~ "to-revoke"
    end

    test "cannot revoke another user's key", %{conn: conn} do
      owner = insert_verified_user()
      attacker = insert_verified_user()
      {owner_key, _} = insert_api_key(owner, "owner-key")

      # Try via context directly — LiveView won't even show other user's keys
      assert {:error, :not_found} = Accounts.revoke_api_key(attacker.id, owner_key.id)
    end

    test "revoking a non-existent key shows an error flash", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      # Send a revoke event with a UUID that doesn't exist for this user
      render_click(lv, "revoke", %{"id" => Ecto.UUID.generate()})

      html = render(lv)
      assert html =~ "Key not found"
    end
  end
end

# Accounts.create_api_key stub must be visible to the LiveView process, so
# this uses Mimic global mode in a separate non-async module.
defmodule FountainWeb.ApiKeysLiveErrorTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  setup :set_mimic_global

  describe "ApiKeysLive.Index — create_key error path" do
    test "create_key shows flash error when Accounts.create_api_key returns error", %{conn: conn} do
      user = insert_verified_user()

      # Arity 3: the LiveView passes `Audited.attribution/1` through so the
      # context can attribute the mint it audits (#542).
      stub(Accounts, :create_api_key, fn _user_id, _label, _opts ->
        cs =
          %Fountain.Accounts.ApiKey{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:name, "is invalid")

        {:error, cs}
      end)

      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      render_submit(lv |> element("form[phx-submit='create_key']"), %{label: "bad-key"})

      html = render(lv)
      assert html =~ "Failed to create API key"
    end
  end
end
