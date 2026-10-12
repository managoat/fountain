defmodule FountainWeb.AccountDataControllerTest do
  @moduledoc """
  Account deletion over the API (#523), behind a typed-email confirmation
  like the UI's.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Accounts

  setup do
    user = insert_user_without_agents()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  describe "DELETE /api/account" do
    test "deletes the account when the email is confirmed", %{conn: conn, user: user, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> delete_json("/api/account", %{"confirm" => user.email})
        |> json_response(200)

      assert body["deleted"] == true
      assert body["user_id"] == user.id
      refute Accounts.get_user(user.id)
    end

    test "refuses without the confirmation and deletes nothing", %{
      conn: conn,
      user: user,
      key: key
    } do
      # `confirm` is required by the schema, so this one is refused before the
      # action runs; the empty-string case below is the controller's own check.
      conn
      |> authed_with_key(key)
      |> delete_json("/api/account", %{})
      |> json_response(422)

      body =
        build_conn()
        |> authed_with_key(key)
        |> delete_json("/api/account", %{"confirm" => ""})
        |> json_response(422)

      assert body["error"] == "confirmation_required"
      assert Accounts.get_user(user.id)
    end

    test "refuses a mismatched confirmation", %{conn: conn, user: user, key: key} do
      conn
      |> authed_with_key(key)
      |> delete_json("/api/account", %{"confirm" => "someone-else@example.com"})
      |> json_response(422)

      assert Accounts.get_user(user.id)
    end

    test "a sprite token cannot delete the account it is running inside", %{
      conn: conn,
      user: user
    } do
      # The escalation this gate exists for: untrusted sandbox code holding a
      # conversation token must not be able to destroy the tenant.
      {_rec, sprite_key} = insert_sprite_api_key(user)

      body =
        conn
        |> authed_with_key(sprite_key)
        |> delete_json("/api/account", %{"confirm" => user.email})
        |> json_response(403)

      assert body["reason"] == "insufficient_scope"
      assert Accounts.get_user(user.id)
    end

    test "one tenant cannot delete another by naming their email", %{conn: conn, key: key} do
      victim = insert_verified_user()

      conn
      |> authed_with_key(key)
      |> delete_json("/api/account", %{"confirm" => victim.email})
      |> json_response(422)

      assert Accounts.get_user(victim.id)
    end

    test "requires authentication", %{conn: conn, user: user} do
      conn
      |> put_req_header("accept", "application/json")
      |> delete_json("/api/account", %{"confirm" => user.email})
      |> json_response(401)

      assert Accounts.get_user(user.id)
    end
  end
end
