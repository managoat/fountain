defmodule FountainWeb.AdminKeysTest do
  use FountainWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Fountain.Accounts

  test "only an admin session reaches key issuance", %{conn: conn} do
    user = insert_verified_user()
    assert {:error, {:live_redirect, _}} = live(login_user(conn, user), "/admin/keys")
  end

  test "admin keys are explicit, revealed once, revocable and tenant scoped", %{conn: conn} do
    user = insert_verified_user()
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    {:ok, view, _} = live(login_user(conn, admin), "/admin/keys")
    view |> form("#create-api-key", label: "operator", admin: "true") |> render_submit()
    [key] = Accounts.list_api_keys(admin.id)
    assert Accounts.ApiKey.admin?(key)
    assert has_element?(view, "#new-key-reveal")
    view |> element("#new-key-reveal button", "I've copied it") |> render_click()
    refute has_element?(view, "#new-key-reveal")
    assert {:error, :not_found} = Accounts.revoke_api_key(insert_verified_user().id, key.id)
    assert {:ok, _} = Accounts.revoke_api_key(admin.id, key.id)
  end
end
