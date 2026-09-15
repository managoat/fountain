defmodule FountainWeb.RegistrationController do
  @moduledoc """
  Handles user registration via:
  - HTML form: GET/POST /auth/register
  - JSON API:  POST /api/auth/register

  and verification-email resend (#445):
  - HTML form: GET/POST /auth/resend-verification
  - JSON API:  POST /api/auth/resend-verification

  Registration is rate-limited to 5 per IP per hour; resend to 5 per IP per
  hour in its own bucket, so a stuck user retrying resend does not burn their
  registration budget (or vice versa).

  The verification email goes through `Workers.VerificationEmail`, not an
  inline send — it used to be a linked `Task.async` that the finishing request
  could kill, and a dropped send here was unrecoverable before the resend
  route existed.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias Fountain.Workers.VerificationEmail
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "registration", max: 5, window_ms: 3_600_000]
       when action in [:create, :api_create]

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "resend_verification", max: 5, window_ms: 3_600_000]
       when action in [:resend, :api_resend]

  tags(["Auth"])

  # The HTML actions serve `/auth/*`, not the API. Declared `false` so
  # `Paths.from_router/1` skips them instead of warning about a missing spec
  # (same treatment as AgentAvatarController's raw-bytes :show).
  operation(:new, false)
  operation(:check_email, false)
  operation(:create, false)
  operation(:resend_form, false)
  operation(:resend, false)

  ## HTML path

  def new(conn, _params) do
    render(conn, :new, errors: %{}, layout: false)
  end

  def check_email(conn, _params) do
    render(conn, :check_email, layout: false)
  end

  def create(conn, %{"user" => user_params}) do
    # Explicit actor: there is no session yet at signup, so derivation would
    # report "system" for a plainly-browser registration — the same caveat
    # `from_conn/4` carries at login.
    case Accounts.register_user(user_params, Audited.attribution(conn, actor: "ui")) do
      # EMAIL_DELIVERY=none: the account self-verified at registration, so
      # "check your email" would send the user to wait for a mail that never
      # comes — the exact dead end auto-verification exists to remove.
      {:ok, %{email_verified_at: %DateTime{}}} ->
        conn
        |> put_flash(:info, "Account created! You can sign in now.")
        |> redirect(to: ~p"/auth/login")

      {:ok, user} ->
        VerificationEmail.enqueue(user)

        conn
        |> put_flash(:info, "Account created! Check your email to verify your address.")
        |> redirect(to: ~p"/auth/check-email")

      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:forbidden)
        |> render(:new, errors: %{email: [registration_message(reason)]}, layout: false)

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

        conn
        |> put_status(:unprocessable_entity)
        |> render(:new, errors: errors, layout: false)
    end
  end

  defp registration_message(:registration_closed),
    do: "Registration is closed on this instance."

  defp registration_message(:email_domain_not_allowed),
    do: "That email domain is not permitted on this instance."

  defp registration_message(_), do: "Registration is not available."

  ## HTML — resend verification

  def resend_form(conn, _params) do
    render(conn, :resend_form, layout: false)
  end

  def resend(conn, params) do
    maybe_resend(params["email"])

    conn
    |> put_flash(:info, resend_message())
    |> redirect(to: ~p"/auth/check-email")
  end

  ## JSON path

  operation(:api_create,
    summary: "Register an account",
    description:
      "Creates the account and sends the verification email. The account " <>
        "cannot mint an API key until it is verified, so a headless bootstrap " <>
        "is register → `POST /api/auth/verify` with the emailed token → " <>
        "`POST /api/auth/token`. Rate-limited to 5 per IP per hour. On an " <>
        "instance with open registration disabled this answers 403 with a " <>
        "reason code.",
    security: [],
    request_body: {"Credentials", "application/json", Schemas.RegisterRequest, required: true},
    responses: [
      created: {"Account created", "application/json", Schemas.RegisterResponse},
      forbidden: {"Registration refused", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Missing fields or validation errors", "application/json", Schemas.Error}
    ]
  )

  def api_create(conn, %{"email" => _, "password" => _} = params) do
    case Accounts.register_user(params, Audited.attribution(conn, actor: "api")) do
      {:ok, %{email_verified_at: %DateTime{}} = user} ->
        conn
        |> put_status(:created)
        |> json(%{
          user_id: user.id,
          message: "Account created. You can sign in now."
        })

      {:ok, user} ->
        VerificationEmail.enqueue(user)

        conn
        |> put_status(:created)
        |> json(%{
          user_id: user.id,
          message: "Check your email to verify your account."
        })

      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: to_string(reason), message: registration_message(reason)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  def api_create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email and password are required"})
  end

  operation(:api_resend,
    summary: "Resend the verification email",
    description:
      "Always 200 with the same message whether the address is unknown, " <>
        "unverified, or already verified — this endpoint is not an account " <>
        "oracle. Rate-limited to 5 per IP per hour in its own bucket, so " <>
        "retrying resend does not burn the registration budget.",
    security: [],
    request_body: {"Address to resend to", "application/json", Schemas.EmailRequest},
    responses: [
      ok: {"Accepted", "application/json", Schemas.MessageResponse}
    ]
  )

  def api_resend(conn, params) do
    maybe_resend(params["email"])

    conn
    |> put_status(:ok)
    |> json(%{message: resend_message()})
  end

  ## Helpers

  # Always the same response whether the address is unknown, unverified, or
  # already verified — same anti-enumeration contract as the password-reset
  # request. A verified account gets nothing: the email would only say
  # "already verified", and sending it would make this an account oracle for
  # anyone watching their own inbox timing.
  defp maybe_resend(email) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      %{email_verified_at: nil} = user -> VerificationEmail.enqueue(user)
      _ -> :ok
    end
  end

  defp maybe_resend(_), do: :ok

  defp resend_message,
    do: "If that address needs verification, a new email is on its way."
end
