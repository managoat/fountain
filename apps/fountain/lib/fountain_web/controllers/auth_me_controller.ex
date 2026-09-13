defmodule FountainWeb.AuthMeController do
  @moduledoc """
  GET /api/auth/me

  Returns the authenticated user's identity. Used by `fountain auth whoami`
  in the CLI to confirm which account an API key belongs to.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias FountainWeb.Schemas

  tags(["Auth"])

  operation(:show,
    summary: "Identity of the authenticated account",
    description:
      "What the presented bearer token resolves to. `fountain auth whoami` " <>
        "calls this to show which account a key belongs to.",
    responses: [
      ok: {"The account", "application/json", Schemas.AuthMeResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      id: user.id,
      email: user.email,
      expires_at: conn.assigns.current_api_key.expires_at,
      role: user.role,
      email_verified: not is_nil(user.email_verified_at),
      # Read side of #525: a client that just bootstrapped an account can see
      # whether the browser will drop this user into the wizard.
      onboarding_completed: not is_nil(user.onboarding_completed_at),
      # Null on a billing-disabled instance, even for an account that was
      # comped before billing was turned off — there is no balance for the
      # flag to be about (#480).
      comped: if(Fountain.Credits.enabled?(), do: user.comped, else: nil),
      # Read-only: whether this deployment brokers egress (ADR 0019), so a
      # client can label the mode instead of probing /api/secret-bindings for
      # a 200 vs 404 (#1154). Deployment-wide since the §9 ratchet retired, so
      # it is the same answer for every account here — still reported per
      # request, because it is what this client's sandboxes will do.
      brokered: Fountain.Broker.configured?(),
      connections_enabled: Fountain.Connections.enabled_for?(user.id)
    })
  end
end
