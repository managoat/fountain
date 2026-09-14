defmodule FountainGoogle.CoreUpgradeTest do
  @moduledoc """
  A core distribution could store Google grants before the provider moved
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

    Application.put_env(:fountain, :broker_listen_port, 14_324)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14324")
    :ok
  end

  test "persisted Google grants remain safe and removable after a core-only upgrade" do
    user = insert_verified_user()
    assert %Provider{slug: "google"} = Platform.get("google")

    fresh =
      insert_connection(user,
        provider: "google",
        account_email: "fresh@example.com",
        access_token: "ya29-fresh"
      )

    expired =
      insert_connection(user,
        provider: "google",
        account_email: "expired@example.com",
        refresh_token: "ya29-refresh",
        expires_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      )

    assert fresh.provider_id == nil
    assert fresh.env_key == "GOOGLE_ACCESS_TOKEN"
    assert Connections.access_token(fresh) == {:ok, "ya29-fresh"}

    assert Connections.implicit_hosts(user.id, fresh.env_key) == [
             "gmail.googleapis.com",
             "www.googleapis.com"
           ]

    # This is the provider registry of BUNDLE_EXTENSIONS=false after the
    # extraction. The existing rows survive; the Google provider does not.
    Application.put_env(:fountain, :extensions, [])
    assert Platform.get("google") == nil
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
