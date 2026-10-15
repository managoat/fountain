defmodule FountainWeb.AccountApiKeysTest do
  @moduledoc "The API keys section of `/account` (`AccountLive.ApiKeys`)."
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  @page "/account?open=api-keys"

  describe "rendering" do
    test "shows existing active keys", %{conn: conn} do
      user = insert_verified_user()
      insert_api_key(user, "ci-deploy")

      {:ok, _lv, html} = live(login_user(conn, user), @page)

      assert html =~ "ci-deploy"
      assert html =~ "ftn_"
    end

    test "renders key with nil last_used_at using em-dash placeholder", %{conn: conn} do
      user = insert_verified_user()
      insert_api_key(user, "never-used")

      {:ok, _lv, html} = live(login_user(conn, user), @page)

      assert html =~ "never-used"
      assert html =~ "—"
    end

    test "shows empty state when no keys exist", %{conn: conn} do
      user = insert_verified_user()
      {:ok, _lv, html} = live(login_user(conn, user), @page)

      assert html =~ "No API keys yet"
    end
  end

  describe "create_key" do
    test "creates a key and shows raw token once", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), @page)

      html = lv |> form("#create-api-key", label: "my-key") |> render_submit()

      assert html =~ "ftn_"
      assert html =~ "Copy"
      assert html =~ "it won&#39;t be shown again" or html =~ "won't be shown again"
    end

    test "dismissing the reveal hides the raw token", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), @page)

      lv |> form("#create-api-key", label: "temp-key") |> render_submit()
      lv |> element("#new-key-reveal button", "I've copied it") |> render_click()

      refute has_element?(lv, "#new-key-reveal")
    end

    test "the new key survives other re-renders and the section folding away", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

      lv |> element("#api-keys-toggle") |> render_click()
      lv |> form("#create-api-key", label: "fold-me") |> render_submit()
      raw = lv |> element("#new-api-key") |> render() |> extract_token()
      assert raw =~ "ftn_"

      # A re-render the parent drives: another section opened and closed.
      lv |> element("#password-toggle") |> render_click()
      lv |> element("#password-toggle") |> render_click()
      assert lv |> element("#new-api-key") |> render() |> extract_token() == raw

      # Folded away: hidden, still holding the key.
      lv |> element("#api-keys-toggle") |> render_click()
      assert has_element?(lv, "#api-keys-body[hidden]")

      lv |> element("#api-keys-toggle") |> render_click()
      refute has_element?(lv, "#api-keys-body[hidden]")
      assert lv |> element("#new-api-key") |> render() |> extract_token() == raw
    end
  end

  describe "admin keys (#2660)" do
    test "an admin can mint an admin key, and an unchecked box mints a plain one", %{conn: conn} do
      admin = insert_verified_user()
      {:ok, admin} = Accounts.update_user_role(admin, "admin")
      {:ok, lv, html} = live(login_user(conn, admin), @page)
      assert html =~ "Admin key"

      lv |> form("#create-api-key", label: "provisioner", admin: "true") |> render_submit()
      lv |> form("#create-api-key", label: "laptop") |> render_submit()

      scopes = Map.new(Accounts.list_api_keys(admin.id), &{&1.name, &1.scopes})
      assert scopes["provisioner"] == ["full", "admin"]
      assert scopes["laptop"] == ["full"]
    end

    test "a non-admin sees no checkbox, and a forged one mints nothing", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, html} = live(login_user(conn, user), @page)
      refute html =~ "Admin key"

      lv
      |> with_target("#api-keys-panel")
      |> render_submit("create_key", %{"label" => "forged", "admin" => "true"})

      assert render(lv) =~ "Failed to create API key"
      assert Accounts.list_api_keys(user.id) == []
    end
  end

  describe "revoke" do
    test "revoking a key removes it from the list", %{conn: conn} do
      user = insert_verified_user()
      {key, _raw} = insert_api_key(user, "to-revoke")

      {:ok, lv, html} = live(login_user(conn, user), @page)
      assert html =~ "to-revoke"

      lv |> element("button[phx-value-id='#{key.id}']", "Revoke") |> render_click()

      refute render(lv) =~ "to-revoke"
    end

    test "cannot revoke another user's key" do
      owner = insert_verified_user()
      attacker = insert_verified_user()
      {owner_key, _} = insert_api_key(owner, "owner-key")

      # Via the context directly — the page never shows another user's keys.
      assert {:error, :not_found} = Accounts.revoke_api_key(attacker.id, owner_key.id)
    end

    test "revoking a non-existent key shows an error flash", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _html} = live(login_user(conn, user), @page)

      lv
      |> with_target("#api-keys-panel")
      |> render_click("revoke", %{"id" => Ecto.UUID.generate()})

      assert render(lv) =~ "Key not found"
    end
  end

  defp extract_token(html) do
    [token] = Regex.run(~r/ftn_[A-Za-z0-9_\-]+/, html)
    token
  end
end

# Accounts.create_api_key stub must be visible to the LiveView process, so
# this uses Mimic global mode in a separate non-async module.
defmodule FountainWeb.AccountApiKeysErrorTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  setup :set_mimic_global

  test "create_key shows flash error when Accounts.create_api_key returns error", %{conn: conn} do
    user = insert_verified_user()

    # Arity 3: the component passes `Audited.attribution/1` through so the
    # context can attribute the mint it audits (#542).
    stub(Accounts, :create_api_key, fn _user_id, _label, _opts ->
      cs =
        %Fountain.Accounts.ApiKey{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:name, "is invalid")

      {:error, cs}
    end)

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account?open=api-keys")

    lv |> form("#create-api-key", label: "bad-key") |> render_submit()

    assert render(lv) =~ "Failed to create API key"
  end
end
