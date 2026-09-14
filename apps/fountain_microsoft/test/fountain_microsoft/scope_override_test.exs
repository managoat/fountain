defmodule FountainMicrosoft.ScopeOverrideTest do
  # Writes global app env (the operator scope override), so never async —
  # and in its own file, per the async-global-config guardrail.
  use ExUnit.Case, async: false

  alias Fountain.Connections.Platform

  test "an operator's scope list replaces the default" do
    Application.put_env(
      :fountain_microsoft,
      :microsoft_oauth_scopes,
      ~w(openid offline_access Mail.Send)
    )

    on_exit(fn -> Application.delete_env(:fountain_microsoft, :microsoft_oauth_scopes) end)

    assert Platform.get("microsoft").scopes == ~w(openid offline_access Mail.Send)
    # the other providers keep their defaults
    assert Platform.get("fixture-svc").scopes == ["read"]
  end

  test "an empty list is unset, not a request for no scopes" do
    Application.put_env(:fountain_microsoft, :microsoft_oauth_scopes, [])
    on_exit(fn -> Application.delete_env(:fountain_microsoft, :microsoft_oauth_scopes) end)

    assert Platform.get("microsoft").scopes == FountainMicrosoft.Provider.default_scopes()
  end
end
