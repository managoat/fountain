defmodule FountainWeb.AuthTokenController do
  @moduledoc """
  POST /api/auth/token

  Exchanges email + password for a fresh API key. Used by `fountain auth login`.
  Rate-limited to 10 attempts per IP per hour.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "auth_token", max: 10, window_ms: 3_600_000]
       when action in [:create]

  tags(["Auth"])

  operation(:create,
    summary: "Exchange email and password for an API key",
    description:
      "The front door: every other `/api/*` endpoint needs the bearer token " <>
        "this returns. Each call mints a **new** full-scope key rather than " <>
        "returning an existing one, so a client that calls it on every run " <>
        "accumulates keys — store the result. The account must be verified; " <>
        "an unverified one is refused with 403 and `reason: email_unverified`. " <>
        "Rate-limited to 10 attempts per IP per hour.",
    # Overrides the spec-wide bearer requirement: this endpoint cannot require
    # the credential it exists to issue.
    security: [],
    request_body: {"Credentials", "application/json", Schemas.AuthTokenRequest, required: true},
    responses: [
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      created: {"A new API key", "application/json", Schemas.AuthTokenResponse},
      unauthorized: {"Invalid email or password", "application/json", Schemas.Error},
      forbidden: {"Email not verified", "application/json", Schemas.Error},
      unprocessable_entity: {"Missing email or password", "application/json", Schemas.Error}
    ]
  )

  def create(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.authenticate_user(email, password) do
      # A full-scope API key is everything the browser session is, minus the
      # verification gate the browser hooks enforce \u2014 so the same gate applies
      # here. Without it, register \u2192 token \u2192 provision worked without ever
      # touching an inbox (#314). 403 rather than 401: the password was right.
      {:ok, %{email_verified_at: nil}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Verify your email address before requesting an API key",
          reason: "email_unverified"
        })

      {:ok, user} ->
        name = "CLI login \u2014 #{DateTime.utc_now() |> DateTime.to_date()}"

        # `:api_public` has no auth plug, so nothing has assigned
        # `:current_user` here and derivation would call this sign-in
        # `"system"`. It is a CLI exchanging a password for a key.
        {:ok, {api_key, raw_key}} =
          Accounts.create_api_key(user.id, name, Audited.attribution(conn, actor: "api"))

        conn
        |> put_status(:created)
        |> json(%{api_key: raw_key, key_id: api_key.id, prefix: api_key.key_prefix})

      {:error, _} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email and password are required"})
  end
end
