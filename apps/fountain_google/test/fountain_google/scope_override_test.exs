defmodule FountainGoogle.ScopeOverrideTest do
  # Writes global app env (the operator scope override), so never async —
  # and in its own file, per the async-global-config guardrail.
  use ExUnit.Case, async: false

  alias Fountain.Connections.Platform

  test "an operator's scope list replaces the default" do
    Application.put_env(:fountain_google, :google_oauth_scopes, ~w(openid email))
    on_exit(fn -> Application.delete_env(:fountain_google, :google_oauth_scopes) end)

    assert Platform.get("google").scopes == ~w(openid email)
    # the other providers keep their defaults
    assert Platform.get("fixture-svc").scopes == ["read"]
  end

  test "an empty list is unset, not a request for no scopes" do
    Application.put_env(:fountain_google, :google_oauth_scopes, [])
    on_exit(fn -> Application.delete_env(:fountain_google, :google_oauth_scopes) end)

    assert Platform.get("google").scopes == FountainGoogle.Provider.default_scopes()
  end
end
