defmodule FountainWeb.RunnerRegistrationTest do
  # async: false because it flips `:runners_enabled`, which is application-wide
  # and off in test config. Its sibling `FountainWeb.RunnerControllerTest` is
  # async: true and asserts the runners-disabled answer instead.
  use FountainWeb.ConnCase, async: false

  alias Fountain.Runners

  setup %{conn: conn} do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)

    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)
    %{conn: authed_with_key(conn, raw_key), user: user}
  end

  describe "GET /api/runners/ws" do
    test "answers a rejected name with the validation error", %{conn: conn, user: user} do
      # The route carries no `:accepts_json`, so a view-rendered error has no
      # format to resolve and raised a 500 here — which reached the daemon as
      # `connect: HTTP 500` and an endless reconnect loop with no reason in it.
      conn =
        conn
        |> put_req_header("upgrade", "websocket")
        |> get("/api/runners/ws", %{"name" => "Has-Uppercase"})

      assert %{"error" => "validation_failed", "errors" => %{"name" => [_ | _]}} =
               json_response(conn, 400)

      assert Runners.list_runners(user.id) == []
    end
  end
end
