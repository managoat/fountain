defmodule FountainSlack.RoundTripTest do
  @moduledoc """
  The console's connect flow, end to end, on the extension's provider
  (#1299, ADR 0054): `user_scope` out, the `authed_user` token in, and a
  platform connection stored with no refresh token and no expiry. Every step
  is core code — the controller, the OAuth client, the store — driven by the
  struct this extension contributes.
  """
  # Turns the broker on and off (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.OAuth

  setup %{conn: conn} do
    user = insert_verified_user()
    enable_connections()
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "the slack round trip: user_scope out, authed_user token in", %{conn: conn, user: user} do
    conn = get(conn, ~p"/connections/slack/start")
    assert redirected_to(conn) =~ "https://slack.com/oauth/v2/authorize?"

    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["scope"] == ""
    assert params["user_scope"] =~ "chat:write"
    assert params["client_id"] == "slack-test-client-id"
    assert params["redirect_uri"] =~ "/connections/slack/callback"
    state = params["state"]

    Req.Test.stub(OAuth, fn req ->
      case req.request_path do
        "/api/oauth.v2.access" ->
          Req.Test.json(req, %{
            "ok" => true,
            "authed_user" => %{
              "id" => "U1",
              "access_token" => "xoxp-7",
              "scope" => "channels:history,chat:write",
              "token_type" => "user"
            }
          })

        "/api/auth.test" ->
          Req.Test.json(req, %{"ok" => true, "user" => "jake", "team" => "goat"})
      end
    end)

    conn =
      conn
      |> recycle()
      |> get(~p"/connections/slack/callback", %{"code" => "the-code", "state" => state})

    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected jake"

    assert [%{provider: "slack", provider_id: nil, env_key: "SLACK_ACCESS_TOKEN"} = stored] =
             Connections.list_connections(user.id)

    # no refresh token and no expiry: good until revoked
    assert stored.refresh_token_ciphertext == nil
    assert stored.expires_at == nil
  end
end
