defmodule FountainWeb.SecretBindingControllerTest do
  use FountainWeb.ConnCase, async: false

  alias Fountain.SecretBindings

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")

    previous_flags = Application.get_env(:fountain, :feature_flag_overrides, %{})
    on_exit(fn -> Application.put_env(:fountain, :feature_flag_overrides, previous_flags) end)

    Application.put_env(
      :fountain,
      :feature_flag_overrides,
      Map.put(previous_flags, "connections", true)
    )

    previous =
      for k <- [:broker_listen_port, :broker_proxy_url],
          do: {k, Application.get_env(:fountain, k)}

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(is_nil(v),
              do: Application.delete_env(:fountain, k),
              else: Application.put_env(:fountain, k, v)
            )
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  test "an account the broker is not on for gets 404 on every route", %{conn: conn} do
    Application.delete_env(:fountain, :broker_listen_port)

    assert %{"error" => "brokerage_not_enabled"} =
             conn |> get("/api/secret-bindings") |> json_response(404)

    assert %{"error" => "brokerage_not_enabled"} =
             conn |> get("/api/secret-bindings/presets") |> json_response(404)

    assert %{"error" => "brokerage_not_enabled"} =
             conn
             |> post("/api/secret-bindings", %{
               key: "K",
               host: "api.example.com",
               auth_type: "bearer"
             })
             |> json_response(404)
  end

  test "create, list, update, delete", %{conn: conn, user: user} do
    assert %{
             "id" => id,
             "key" => "STRIPE_SECRET_KEY",
             "host" => "api.stripe.com",
             "auth_type" => "bearer",
             "enabled" => true
           } =
             conn
             |> post("/api/secret-bindings", %{
               key: "STRIPE_SECRET_KEY",
               host: "api.stripe.com",
               auth_type: "bearer"
             })
             |> json_response(201)

    assert %{"data" => [%{"id" => ^id}]} =
             conn |> get("/api/secret-bindings") |> json_response(200)

    assert %{"enabled" => false, "host" => "api.stripe.com:443"} =
             conn
             |> patch("/api/secret-bindings/#{id}", %{enabled: false, host: "api.stripe.com:443"})
             |> json_response(200)

    assert SecretBindings.enabled_by_key(user.id) == %{}

    assert conn |> delete("/api/secret-bindings/#{id}") |> response(204)
    assert %{"data" => []} = conn |> get("/api/secret-bindings") |> json_response(200)
  end

  test "validation errors are 422", %{conn: conn} do
    assert %{"errors" => errors} =
             conn
             |> post("/api/secret-bindings", %{key: "K", host: "10.0.0.1", auth_type: "basic"})
             |> json_response(422)

    assert Map.has_key?(errors, "host")
    assert Map.has_key?(errors, "username")
  end

  test "another tenant's binding is not found", %{conn: conn} do
    other = insert_verified_user()

    {:ok, b} =
      SecretBindings.create_binding(other.id, %{
        "key" => "K",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })

    assert conn |> patch("/api/secret-bindings/#{b.id}", %{enabled: false}) |> json_response(404)
    assert conn |> delete("/api/secret-bindings/#{b.id}") |> json_response(404)
  end

  test "presets carry the catalog", %{conn: conn} do
    assert %{"data" => presets} =
             conn |> get("/api/secret-bindings/presets") |> json_response(200)

    assert length(presets) == 35
    assert Enum.any?(presets, &(&1["id"] == "github" and &1["suggested_key"] == "GITHUB_TOKEN"))
  end
end
