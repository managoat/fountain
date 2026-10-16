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

    test "the new key survives section navigation", %{conn: conn} do
      user = insert_verified_user()
      {:ok, lv, _} = live(login_user(conn, user), @page)
      lv |> form("#create-api-key", label: "keep-me") |> render_submit()
      raw = lv |> element("#new-api-key") |> render() |> extract_token()
      lv |> element("a[data-section=security]") |> render_click()
      assert has_element?(lv, "#api-keys[hidden]")
      lv |> element("a[data-section=api-keys]") |> render_click()
      refute has_element?(lv, "#api-keys[hidden]")
      assert lv |> element("#new-api-key") |> render() |> extract_token() == raw
    end

    test "even an admin's account form only creates ordinary keys", %{conn: conn} do
      user = insert_verified_user(role: "admin")
      {:ok, lv, _} = live(login_user(conn, user), @page)
      refute has_element?(lv, "#create-api-key input[name=admin]")

      lv
      |> with_target("#api-keys-panel")
      |> render_submit("create_key", %{"label" => "ordinary", "admin" => "true"})

      assert [%{scopes: ["full"]}] = Accounts.list_api_keys(user.id)
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
