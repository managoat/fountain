defmodule FountainSlack.ScopeOverrideTest do
  # Writes global app env (the operator scope override), so never async —
  # and in its own file, per the async-global-config guardrail.
  use ExUnit.Case, async: false

  alias Fountain.Connections.Platform

  test "an operator's user-scope list replaces the default, and user_scope follows it" do
    Application.put_env(:fountain_slack, :slack_oauth_user_scopes, ~w(chat:write users:read))
    on_exit(fn -> Application.delete_env(:fountain_slack, :slack_oauth_user_scopes) end)

    slack = Platform.get("slack")
    assert slack.scopes == ~w(chat:write users:read)
    assert slack.authorize_params["user_scope"] == "chat:write users:read"
    # the host's own providers keep their defaults
    assert "https://www.googleapis.com/auth/gmail.modify" in Platform.get("google").scopes
  end

  test "an empty list is unset, not a request for no scopes" do
    Application.put_env(:fountain_slack, :slack_oauth_user_scopes, [])
    on_exit(fn -> Application.delete_env(:fountain_slack, :slack_oauth_user_scopes) end)

    assert Platform.get("slack").scopes == FountainSlack.Provider.default_scopes()
  end
end
