defmodule FountainWeb.SecretBindingsLiveTest do
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.SecretBindings

  setup do
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
    :ok
  end

  test "hidden and redirected for an account the broker is not on for", %{conn: conn} do
    user = insert_verified_user()
    Application.delete_env(:fountain, :broker_listen_port)
    conn = login_user(conn, user)

    refute conn |> get(~p"/account") |> html_response(200) =~ "Credential bindings"
    assert {:error, {:live_redirect, %{to: "/account"}}} = live(conn, ~p"/account/bindings")
  end

  test "lists, binds from a preset, toggles and unbinds", %{conn: conn} do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)

    {:ok, _} =
      Fountain.Environments.upsert_secret(
        env,
        %{"key" => "STRIPE_SECRET_KEY", "value" => "sk_live_never_shown_9f3"},
        <<1::256>>
      )

    conn = login_user(conn, user)

    assert conn |> get(~p"/account") |> html_response(200) =~ "Credential bindings"

    {:ok, lv, html} = live(conn, ~p"/account/bindings")
    assert html =~ "broker.test"
    assert html =~ "No bindings yet"
    # The stored-but-unbound key is offered, and never a value.
    assert html =~ "STRIPE_SECRET_KEY"
    refute html =~ "sk_live_never_shown_9f3"

    # A preset prefills the host and shape; the name stays the one typed.
    lv |> element("#preset-stripe") |> render_click()
    html = render(lv)
    assert html =~ ~s(value="api.stripe.com")

    html =
      lv
      |> form("form[phx-submit=save]",
        binding: %{key: "STRIPE_SECRET_KEY", host: "api.stripe.com", auth_type: "bearer"}
      )
      |> render_submit()

    assert html =~ "STRIPE_SECRET_KEY is now attached to api.stripe.com"

    assert [%{key: "STRIPE_SECRET_KEY", host: "api.stripe.com", enabled: true} = b] =
             SecretBindings.list_bindings(user.id)

    assert html =~ "Authorization: Bearer &lt;secret&gt;"

    lv |> element("#binding-#{b.id} button", "Disable") |> render_click()
    refute SecretBindings.get_binding(b.id, user.id).enabled

    lv |> element("#binding-#{b.id} button", "Unbind") |> render_click()
    assert SecretBindings.list_bindings(user.id) == []
  end

  test "a bad host is refused with the reason", %{conn: conn} do
    user = insert_verified_user()
    {:ok, lv, _} = conn |> login_user(user) |> live(~p"/account/bindings")

    html =
      lv
      |> form("form[phx-submit=save]",
        binding: %{key: "K", host: "10.0.0.1", auth_type: "bearer"}
      )
      |> render_submit()

    assert html =~ "IP address"
    assert SecretBindings.list_bindings(user.id) == []
  end
end
