defmodule FountainMicrosoft.CoreUpgradeTest do
  @moduledoc """
  A core distribution could store Microsoft grants before the provider moved
  into an extension. Removing the extension must leave those rows manageable.
  """
  # This upgrade changes the VM's installed extensions and broker config.
  use Fountain.DataCase, async: false

  alias Fountain.Connections
  alias Fountain.Connections.{OAuth, Platform, Provider}
  alias Fountain.Conversations.Egress

  setup do
    previous =
      for key <- [:extensions, :broker_listen_port, :broker_proxy_url],
          do: {key, Application.fetch_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:fountain, key, value)
          :error -> Application.delete_env(:fountain, key)
        end
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    :ok
  end

  test "persisted Microsoft grants remain safe and removable after a core-only upgrade" do
    user = insert_verified_user()
    assert %Provider{slug: "microsoft"} = Platform.get("microsoft")

    fresh =
      insert_connection(user,
        provider: "microsoft",
        account_email: "fresh@corp.example",
        access_token: "graph-fresh"
      )

    expired =
      insert_connection(user,
        provider: "microsoft",
        account_email: "expired@corp.example",
        refresh_token: "graph-refresh",
        expires_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      )

    assert fresh.provider_id == nil
    assert fresh.env_key == "MICROSOFT_ACCESS_TOKEN"
    assert Connections.access_token(fresh) == {:ok, "graph-fresh"}
    assert Connections.implicit_hosts(user.id, fresh.env_key) == ["graph.microsoft.com"]

    # This is the provider registry of BUNDLE_EXTENSIONS=false after the
    # extraction. The existing rows survive; the Microsoft provider does not.
    Application.put_env(:fountain, :extensions, [])
    assert Platform.get("microsoft") == nil
    assert Connections.provider_for(fresh) == nil
    assert Connections.get_connection(fresh.id, user.id).status == "active"
    Req.Test.stub(OAuth, fn _ -> flunk("an absent provider must not receive a request") end)

    assert Connections.access_token(fresh) == {:error, :provider_unavailable}
    assert Connections.access_token(expired) == {:error, :provider_unavailable}
    assert Connections.implicit_hosts(user.id, fresh.env_key) == []
    assert Connections.synthetic_secrets(user.id) == %{}
    assert Egress.brokered?()

    assert Egress.add_connection_secrets(user.id, %{"KEEP" => "value"}, %{}, nil) ==
             {%{"KEEP" => "value"}, %{}, []}

    assert {:ok, %{status: "revoked"}} = Connections.revoke(fresh)
    assert Connections.get_connection(fresh.id, user.id).status == "revoked"
    assert {:ok, _} = Connections.delete(expired)
    assert Connections.get_connection(expired.id, user.id) == nil
  end
end
