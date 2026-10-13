defmodule FountainWeb.FrontDoorTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "GET /" do
    test "sends a signed-out visitor through the console to sign in", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/dashboard"

      assert {:error, {:redirect, %{to: path}}} =
               live(build_conn(), ~p"/dashboard")

      assert path =~ "/auth/login"
    end

    test "sends a signed-in visitor to the console", %{conn: conn} do
      user = insert_verified_user()
      assert conn |> login_user(user) |> get(~p"/") |> redirected_to() == ~p"/dashboard"
    end

    test "the hosted product's pages are not served", %{conn: conn} do
      for path <- ~w(/terms /privacy /start /integrations /self-hosted /faq) do
        assert conn |> get(path) |> response(404), "#{path} is still served"
      end
    end
  end
end
