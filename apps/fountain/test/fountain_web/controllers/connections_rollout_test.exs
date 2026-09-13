defmodule FountainWeb.ConnectionsRolloutTest do
  @moduledoc """
  The two gates in front of Connections, and which doors each one holds.

  The broker closes everything: without it a token cannot be kept out of a
  sandbox, so the feature does not exist for that account. The `connections`
  rollout flag closes only the doors that **add** a way of getting a
  credential. Everything that lists, revokes, unbinds or deletes stays open
  for a brokered account, because a tenant whose flag goes off keeps every
  credential already brokered into their sandboxes and has to be able to take
  it away (#1693).
  """
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers
  import Phoenix.LiveViewTest

  alias Fountain.Connections.OAuth
  alias Fountain.SecretBindings

  setup do
    user = insert_verified_user()
    {_key, raw} = insert_api_key(user)
    enable_connections()
    {:ok, user: user, raw: raw}
  end

  defp flag(on?),
    do: Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => on?})

  defp api(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("accept", "application/json")
  end

  defp binding_for(user, attrs \\ %{}) do
    {:ok, binding} =
      SecretBindings.create_binding(
        user.id,
        Map.merge(
          %{"key" => "STRIPE_SECRET_KEY", "host" => "api.stripe.com", "auth_type" => "bearer"},
          attrs
        ),
        actor: "ui"
      )

    binding
  end

  for flag <- [true, false] do
    test "the broker off closes every route, with the flag #{flag}", ctx do
      Application.delete_env(:fountain, :broker_listen_port)
      flag(unquote(flag))

      routes =
        FountainWeb.Router.__routes__()
        |> Enum.filter(
          &String.starts_with?(&1.path, [
            "/api/connections",
            "/api/connection-providers",
            "/api/secret-bindings"
          ])
        )

      assert length(routes) >= 15

      for route <- routes do
        path = Regex.replace(~r/:[a-z_]+/, route.path, Ecto.UUID.generate())
        result = dispatch(api(ctx.raw), @endpoint, route.verb, path, %{})

        expected =
          if String.starts_with?(path, "/api/secret-bindings"),
            do: "brokerage_not_enabled",
            else: "connections_not_enabled"

        assert json_response(result, 404)["error"] == expected, "#{route.verb} #{path}"
      end
    end
  end

  describe "the flag off, the broker on" do
    test "an account that holds rows can still list and delete every one of them", ctx do
      connection = insert_connection(ctx.user, account_email: "me@example.com")
      provider = insert_provider(ctx.user)
      binding = binding_for(ctx.user)
      flag(false)

      conn = api(ctx.raw)

      assert %{"data" => [_]} = conn |> get("/api/connections") |> json_response(200)

      assert %{"id" => _} =
               conn |> get("/api/connections/#{connection.id}") |> json_response(200)

      Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)
      assert conn |> delete("/api/connections/#{connection.id}") |> response(204)

      assert %{"data" => providers} =
               conn |> get("/api/connection-providers") |> json_response(200)

      assert Enum.any?(providers, &(&1["id"] == provider.id))
      assert conn |> delete("/api/connection-providers/#{provider.id}") |> response(204)

      assert %{"data" => [_]} = conn |> get("/api/secret-bindings") |> json_response(200)
      assert conn |> delete("/api/secret-bindings/#{binding.id}") |> response(204)

      assert SecretBindings.list_bindings(ctx.user.id) == []
    end

    test "adding one is still refused", ctx do
      provider = insert_provider(ctx.user)
      binding = binding_for(ctx.user)
      flag(false)

      conn = api(ctx.raw)

      assert %{"error" => "connections_not_enabled"} =
               conn
               |> post("/api/connection-providers", provider_attrs(%{"slug" => "another"}))
               |> json_response(404)

      assert %{"error" => "connections_not_enabled"} =
               conn
               |> patch("/api/connection-providers/#{provider.id}", %{"name" => "Renamed"})
               |> json_response(404)

      assert %{"error" => "connections_not_enabled"} =
               conn
               |> post("/api/connection-providers/#{provider.id}/discover", %{})
               |> json_response(404)

      assert %{"error" => "brokerage_not_enabled"} =
               conn
               |> post("/api/secret-bindings", %{
                 key: "K",
                 host: "api.example.com",
                 auth_type: "bearer"
               })
               |> json_response(404)

      # A binding's host is where the credential goes, so retargeting one is
      # adding a credential path, not managing an existing one.
      assert %{"error" => "brokerage_not_enabled"} =
               conn
               |> patch("/api/secret-bindings/#{binding.id}", %{host: "api.attacker.example"})
               |> json_response(404)

      assert %{host: "api.stripe.com"} = SecretBindings.get_binding(binding.id, ctx.user.id)
    end

    # `enabled` is the one field whose two values sit on different sides of the
    # gate: false takes a credential off a host, true puts it back on.
    test "a binding can be disabled but not enabled again, over the API", ctx do
      binding = binding_for(ctx.user)
      flag(false)
      conn = api(ctx.raw)

      assert %{"enabled" => false} =
               conn
               |> patch("/api/secret-bindings/#{binding.id}", %{enabled: false})
               |> json_response(200)

      assert %{"error" => "brokerage_not_enabled"} =
               conn
               |> patch("/api/secret-bindings/#{binding.id}", %{enabled: true})
               |> json_response(404)

      refute SecretBindings.get_binding(binding.id, ctx.user.id).enabled

      # Not a loophole: a disabling that carries anything else is an edit.
      assert %{"error" => "brokerage_not_enabled"} =
               conn
               |> patch("/api/secret-bindings/#{binding.id}", %{
                 enabled: false,
                 host: "api.attacker.example"
               })
               |> json_response(404)

      assert %{host: "api.stripe.com"} = SecretBindings.get_binding(binding.id, ctx.user.id)
    end

    test "the console cannot enable a disabled binding either", ctx do
      binding = binding_for(ctx.user, %{"enabled" => false})
      flag(false)

      {:ok, view, _html} = live(login_user(build_conn(), ctx.user), "/account/bindings")

      # The button is gone, and the event behind it is refused.
      refute has_element?(view, "[phx-click=toggle][phx-value-id='#{binding.id}']")

      assert render_click(view, "toggle", %{"id" => binding.id}) =~ "New bindings are off"
      refute SecretBindings.get_binding(binding.id, ctx.user.id).enabled
    end

    test "the console still disables an enabled binding", ctx do
      binding = binding_for(ctx.user)
      flag(false)

      {:ok, view, _html} = live(login_user(build_conn(), ctx.user), "/account/bindings")
      assert has_element?(view, "[phx-click=toggle][phx-value-id='#{binding.id}']")
      assert render_click(view, "toggle", %{"id" => binding.id}) =~ "disabled"
      refute SecretBindings.get_binding(binding.id, ctx.user.id).enabled
    end

    test "the OAuth round trip is refused and the console says so", ctx do
      flag(false)
      conn = login_user(build_conn(), ctx.user)

      for path <- ["/connections/google/start", "/connections/google/callback"] do
        assert conn |> get(path) |> redirected_to() == "/account"
      end
    end

    test "both pages open, the nav still links them, and the controls that add are gone", ctx do
      connection = insert_connection(ctx.user, account_email: "me@example.com")
      binding = binding_for(ctx.user)
      flag(false)
      conn = login_user(build_conn(), ctx.user)

      html = conn |> get("/account") |> html_response(200)
      assert html =~ "Credential bindings"
      assert html =~ "href=\"/account/connections\""

      {:ok, view, html} = live(conn, "/account/connections")
      assert html =~ "me@example.com"
      assert has_element?(view, "[data-role=connect-disabled]")
      refute has_element?(view, "[data-role=new-provider]")
      refute has_element?(view, "#mcp-discover-form")

      # Revoking and removing are the doors that must never close.
      Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)
      html = render_click(view, "revoke", %{"id" => connection.id})
      assert html =~ "Revoked me@example.com"
      render_click(view, "delete", %{"id" => connection.id})
      assert Fountain.Connections.list_connections(ctx.user.id) == []

      {:ok, bindings_view, html} = live(conn, "/account/bindings")
      assert html =~ "STRIPE_SECRET_KEY"
      assert has_element?(bindings_view, "[data-role=bind-disabled]")
      refute has_element?(bindings_view, "#binding-form-0")

      render_click(bindings_view, "delete", %{"id" => binding.id})
      assert SecretBindings.list_bindings(ctx.user.id) == []
    end

    test "an agent form still offers the connections the account holds", ctx do
      insert_connection(ctx.user, account_email: "me@example.com")
      agent = insert_agent(user_id: ctx.user.id)
      flag(false)

      {:ok, view, _html} = live(login_user(build_conn(), ctx.user), "/agents/#{agent.id}/edit")
      view |> element("button", "+ Add server") |> render_click()

      html =
        view
        |> element("form[phx-change=validate]")
        |> render_change(%{
          "agent" => %{"mcp_servers" => %{"0" => %{"name" => "gmail", "kind" => "connection"}}}
        })

      assert html =~ "me@example.com (google)"
    end

    test "an event that would add something is refused even when pushed at the page", ctx do
      flag(false)
      conn = login_user(build_conn(), ctx.user)

      {:ok, view, _html} = live(conn, "/account/connections")
      assert render_click(view, "new_provider", %{}) =~ "not enabled for this account"
      refute has_element?(view, "#provider-form")

      {:ok, bindings_view, _html} = live(conn, "/account/bindings")

      assert render_click(bindings_view, "save", %{
               "binding" => %{
                 "key" => "K",
                 "host" => "api.example.com",
                 "auth_type" => "bearer"
               }
             }) =~ "New bindings are off"

      assert SecretBindings.list_bindings(ctx.user.id) == []
    end
  end

  test "brokering stays visible while Connections is off, and both on opens the surface", ctx do
    flag(false)
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> ctx.raw)

    assert %{"brokered" => true, "connections_enabled" => false} =
             conn |> get("/api/auth/me") |> json_response(200)

    flag(true)

    assert %{"brokered" => true, "connections_enabled" => true} =
             conn |> get("/api/auth/me") |> json_response(200)

    assert %{"data" => []} = conn |> get("/api/connections") |> json_response(200)
  end

  test "a deployment with no PostHog keeps Connections rather than losing it on upgrade", ctx do
    # The self-host case (#1693): no override, no flag service. The upgrade
    # that introduced the flag must not take the feature away.
    previous = Application.get_env(:fountain, :posthog_project_api_key)

    on_exit(fn ->
      if previous, do: Application.put_env(:fountain, :posthog_project_api_key, previous)
      Fountain.FeatureFlags.reset()
    end)

    Application.put_env(:fountain, :feature_flag_overrides, %{})
    Application.delete_env(:fountain, :posthog_project_api_key)
    Fountain.FeatureFlags.reset()

    assert Fountain.Connections.enabled_for?(ctx.user.id)

    assert %{"connections_enabled" => true} =
             api(ctx.raw) |> get("/api/auth/me") |> json_response(200)
  end
end
