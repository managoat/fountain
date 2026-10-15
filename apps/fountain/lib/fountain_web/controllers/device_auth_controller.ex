defmodule FountainWeb.DeviceAuthController do
  @moduledoc """
  Device authorization for the CLI (#1305, RFC 8628 shape).

  `POST /api/auth/device` starts a grant; the human approves it at `/device`
  in a signed-in browser; `POST /api/auth/device/token` is what the CLI polls
  until the approval mints a key. This is the login path for accounts that
  signed up with GitHub and therefore cannot use `POST /api/auth/token` —
  they have no password to exchange.

  Both endpoints are unauthenticated by design (the whole point is that the
  caller has no credential yet) and rate-limited: the start like the other
  auth front doors, the poll generously enough for one grant's lifetime of
  five-second polls.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.OAuth
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "device_auth", max: 10, window_ms: 3_600_000]
       when action in [:create]

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "device_token", max: 600, window_ms: 3_600_000]
       when action in [:token]

  tags(["Auth"])

  operation(:create,
    summary: "Start a device-authorization grant",
    description:
      "The CLI login path for accounts without a password (\"Sign up with " <>
        "GitHub\"). Show the user `user_code` and send them to " <>
        "`verification_uri` (or open `verification_uri_complete`), then poll " <>
        "`POST /api/auth/device/token` with `device_code` every `interval` " <>
        "seconds until they approve. The grant expires after `expires_in` " <>
        "seconds. A client that names itself with `client_name` is shown by " <>
        "that name on the approval page, and the key it collects carries it. " <>
        "Rate-limited to 10 grants per IP per hour.",
    security: [],
    request_body:
      {"Device authorization request", "application/json", Schemas.DeviceAuthRequest,
       required: false},
    responses: [
      created: {"A new device grant", "application/json", Schemas.DeviceAuthResponse},
      bad_request: {"`client_name` is not a string", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    case Map.get(params, "client_name") do
      name when is_nil(name) or is_binary(name) ->
        start(conn, name)

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: "client_name must be a string"})
    end
  end

  defp start(conn, client_name) do
    case OAuth.start_device_grant(client_name: client_name) do
      {:ok, grant} ->
        conn
        |> put_status(:created)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{
          device_code: grant.device_code,
          user_code: grant.user_code,
          verification_uri: url(~p"/device"),
          verification_uri_complete: url(~p"/device?#{[code: grant.user_code]}"),
          expires_in: grant.expires_in,
          interval: grant.interval
        })

      {:error, _} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "server_error"})
    end
  end

  operation(:token,
    summary: "Poll a device grant for the API key",
    description:
      "Polled by the CLI with the `device_code` from `POST /api/auth/device`. " <>
        "Until the user decides, 400 `authorization_pending` (or `slow_down` " <>
        "when polled faster than `interval`). A denial is 400 `access_denied`; " <>
        "a timed-out grant is 400 `expired_token`; an unknown or already-used " <>
        "code is 400 `invalid_grant`. On approval, 201 with a full-scope API " <>
        "key — the same shape `POST /api/auth/token` returns — and the grant " <>
        "is consumed.",
    security: [],
    request_body:
      {"Device token request", "application/json", Schemas.DeviceTokenRequest, required: true},
    responses: [
      created: {"A new API key", "application/json", Schemas.AuthTokenResponse},
      bad_request:
        {"authorization_pending / slow_down / access_denied / expired_token / invalid_grant",
         "application/json", Schemas.Error}
    ]
  )

  def token(conn, %{"device_code" => device_code}) when is_binary(device_code) do
    # No session, so derivation would call the mint "system"; it is the CLI
    # collecting the key a browser approval promised it.
    case OAuth.poll_device_grant(device_code,
           actor: "api",
           request_ip: Audited.attribution(conn)[:request_ip]
         ) do
      {:ok, %{access_token: raw_key, api_key: api_key}} ->
        conn
        |> put_status(:created)
        |> put_resp_header("cache-control", "no-store")
        |> json(%{api_key: raw_key, key_id: api_key.id, prefix: api_key.key_prefix})

      {:error, :server_error} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "server_error"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})
    end
  end

  def token(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "invalid_grant"})
  end
end
