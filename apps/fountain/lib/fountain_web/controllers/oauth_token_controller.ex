defmodule FountainWeb.OAuthTokenController do
  @moduledoc """
  The token half of Fountain's OAuth 2.0 authorization server (#818):
  `POST /api/oauth/token` exchanges a consent code (with its PKCE verifier)
  for an API key; `POST /api/oauth/revoke` revokes the key an app presents
  when it signs out. Public clients — no client secret, so the token route
  is unauthenticated (and rate-limited), and the code + verifier + exact
  redirect URI are the whole proof.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.OAuth
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "oauth_token", max: 30, window_ms: 3_600_000]
       when action in [:token]

  tags(["Auth"])

  operation(:token,
    summary: "Exchange an authorization code for an API key",
    description:
      "OAuth 2.0 authorization code grant with PKCE (S256), for registered public " <>
        "clients — Managoat's own browser apps on other origins. The user consented at " <>
        "`/oauth/authorize`; this exchanges the resulting `code` plus the `code_verifier` " <>
        "for a full-scope API key that expires in 30 days and lists under Account → API " <>
        "keys as `oauth:<client_id>`. Every way a grant can be wrong (unknown, used, " <>
        "expired, wrong client, wrong redirect_uri, wrong verifier) is one answer: 400 " <>
        "`invalid_grant`. Rate-limited to 30 attempts per IP per hour.",
    request_body: {"Token request", "application/json", Schemas.OAuthTokenRequest},
    responses: [
      ok: {"Token", "application/json", Schemas.OAuthTokenResponse},
      bad_request: {"invalid_grant / unsupported_grant_type", "application/json", Schemas.Error}
    ]
  )

  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    case OAuth.exchange(params, request_ip: FountainWeb.Audited.attribution(conn)[:request_ip]) do
      {:ok, %{access_token: token, expires_in: ttl}} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{access_token: token, token_type: "bearer", expires_in: ttl})

      {:error, :invalid_grant} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_grant"})

      {:error, _} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "server_error"})
    end
  end

  def token(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "unsupported_grant_type"})
  end

  operation(:revoke,
    summary: "Revoke the presented token",
    description:
      "Revokes the API key in the `Authorization` header — what an app does on sign-out. " <>
        "Idempotent: an already-revoked key is 204 too (it would not have authenticated).",
    responses: [no_content: "Revoked"]
  )

  def revoke(conn, _params) do
    _ = OAuth.revoke(conn.assigns.current_api_key, FountainWeb.Audited.attribution(conn))
    send_resp(conn, :no_content, "")
  end
end
