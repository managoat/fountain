defmodule FountainGoogle.ConnectionsLiveTest do
  # Installation and brokerage are global application configuration.
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Fountain.BrokerTestHelpers

  test "only platform Google grants receive Gmail setup instructions after installation", ctx do
    extensions = Application.fetch_env!(:fountain, :extensions)
    on_exit(fn -> Application.put_env(:fountain, :extensions, extensions) end)
    enable_connections()
    user = insert_verified_user()

    Application.put_env(:fountain, :extensions, [])
    provider = insert_provider(user, slug: "google")
    tenant = insert_connection(user, provider: provider)

    Application.put_env(:fountain, :extensions, [FountainGoogle.Extension])
    platform = insert_connection(user, provider: "google")
    {:ok, view, _} = ctx.conn |> login_user(user) |> live(~p"/account/connections")

    tenant_card = view |> element("#connection-#{tenant.id}") |> render()
    assert tenant_card =~ "https://…/mcp"
    assert tenant_card =~ "stdio"
    refute tenant_card =~ "&quot;gmail&quot;"

    platform_card = view |> element("#connection-#{platform.id}") |> render()
    assert platform_card =~ "&quot;gmail&quot;"
    refute platform_card =~ "https://…/mcp"

    Application.put_env(:fountain, :extensions, [])
    {:ok, core_view, _} = ctx.conn |> login_user(user) |> live(~p"/account/connections")
    core_card = core_view |> element("#connection-#{platform.id}") |> render()
    assert core_card =~ "https://…/mcp"
    refute core_card =~ "&quot;gmail&quot;"
  end
end
