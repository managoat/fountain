defmodule FountainWeb.CreditsApiController do
  @moduledoc """
  Billing self-serve over the API (#524).

  All user-facing billing lived in `CreditsLive`: the balance, the usage
  summary and Checkout minting. `GET /api/auth/me` exposed nothing about
  money, so a CLI user who hit the credit gate got a 402 with no programmatic
  way out of it. This is the way out: read the balance, mint a Checkout URL.

  Stripe requires a browser to finish, so URLs are the deliverable — this mints
  them, the user opens them. Return URLs are server-chosen on purpose: a
  caller-supplied one would be an open redirect wearing a Stripe badge.

  Lives in `ee/` with the rest of billing (#472).
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Billing
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Billing"])

  # The operation ids are keys in the SDK's generated `operations` map, so
  # they keep the module's old name (#1144) rather than breaking a consumer
  # over a rename.
  operation(:show,
    operation_id: "FountainWeb.BillingApiController.show",
    summary: "Credit balance and current-month usage",
    description:
      "The credit balance, what of it expires and when, and the usage numbers " <>
        "the billing page shows, measured over the calendar month. " <>
        "On an instance with billing disabled this is a 404 carrying " <>
        "`billing: \"disabled\"`, mirroring the UI, which redirects away from " <>
        "the billing page entirely.",
    responses: [
      ok: {"Billing", "application/json", Schemas.BillingResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Billing disabled", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    with :ok <- require_billing() do
      user = conn.assigns.current_user
      period = Fountain.Usage.month_range()

      render(conn, :show,
        user: user,
        usage: Billing.usage_summary(user.id, period.start, period.end),
        credits: Fountain.Credits.summary(user),
        sandbox_cap: Fountain.Quotas.sandbox_limit_for(user),
        period: period
      )
    end
  end

  operation(:credits_checkout,
    operation_id: "FountainWeb.BillingApiController.credits_checkout",
    summary: "Mint a Stripe Checkout URL for a credit pack",
    description:
      "A one-time payment for one of the packs this deployment sells " <>
        "(`GET /api/account/billing` lists them under `credits.packs_cents`). " <>
        "The balance moves when Stripe's webhook confirms payment, not when " <>
        "this returns. Refused for a comped account with `comped`, and for an " <>
        "amount that is not a pack with `unknown_pack`.",
    request_body: {"Pack", "application/json", Schemas.CreditsCheckoutRequest, required: true},
    responses: [
      ok: {"Stripe URL", "application/json", Schemas.StripeUrlResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Billing disabled", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error},
      bad_gateway: {"Stripe unreachable", "application/json", Schemas.Error}
    ]
  )

  def credits_checkout(conn, params) do
    user = conn.assigns.current_user

    with :ok <- require_billing(),
         {:ok, cents} <- pack_param(params) do
      user
      |> Fountain.Credits.Purchases.checkout_url(cents, return_url())
      |> render_url(conn)
    else
      {:error, :bad_cents} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "unknown_pack", message: "cents must be one of the packs on offer."})

      other ->
        other
    end
  end

  defp pack_param(%{"cents" => cents}) when is_integer(cents) and cents > 0, do: {:ok, cents}
  defp pack_param(_), do: {:error, :bad_cents}

  defp require_billing do
    if Fountain.Credits.enabled?(), do: :ok, else: {:error, :billing_disabled}
  end

  defp render_url({:ok, url}, conn), do: render(conn, :url, url: url)

  defp render_url({:error, :comped}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "comped",
      message: "This account is comped — there is nothing to pay and nothing to manage."
    })
  end

  defp render_url({:error, :unknown_pack}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unknown_pack", message: "cents must be one of the packs on offer."})
  end

  defp render_url({:error, _reason}, conn), do: stripe_unreachable(conn)

  defp stripe_unreachable(conn) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{error: "stripe_unreachable", message: "Could not reach Stripe. Try again."})
  end

  defp return_url, do: FountainWeb.Endpoint.url() <> "/account/billing"
end
