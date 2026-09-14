defmodule FountainWeb.WebhookEndpointController do
  @moduledoc """
  Webhook endpoint CRUD, the delivery log, test sends and redelivery (#700).

  These are the webhooks Fountain *sends*, as opposed to the ones it
  receives (Stripe's, under `/api/stripe`); they live under `/api/webhooks`
  because that is where an integrator looks.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Webhooks
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  tags(["Webhooks"])

  operation(:index,
    summary: "List webhook endpoints",
    description:
      "Metadata only. The signing secret is returned once, at creation and at each " <>
        "rotation, and is not recoverable.",
    responses: [
      ok: {"Endpoints", "application/json", Schemas.WebhookEndpointListResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    render(conn, :index, endpoints: Webhooks.list_endpoints(conn.assigns.current_user.id))
  end

  operation(:show,
    summary: "Get one webhook endpoint",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"The endpoint", "application/json", Schemas.WebhookEndpointResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such endpoint on this account", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, endpoint} <- fetch(conn, id) do
      render(conn, :show, endpoint: endpoint)
    end
  end

  operation(:create,
    summary: "Create a webhook endpoint",
    description:
      "The response is the only time the signing secret is available. A URL pointing at " <>
        "loopback, link-local (the cloud metadata address included) or RFC1918 space is " <>
        "refused here and again at every delivery.",
    request_body:
      {"The endpoint", "application/json", Schemas.WebhookEndpointCreateRequest, required: true},
    responses: [
      created:
        {"The endpoint, with its secret", "application/json",
         Schemas.WebhookEndpointCreatedResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid URL or event filter", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, {endpoint, secret}} <-
           Webhooks.create_endpoint(user.id, endpoint_attrs(params), Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:created, endpoint: endpoint, secret: secret)
    end
  end

  operation(:update,
    summary: "Update a webhook endpoint",
    description:
      "Any subset of url, description, event_types and status. Setting `status` to " <>
        "`active` on an endpoint that was auto-disabled also clears its failure count.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Fields to change", "application/json", Schemas.WebhookEndpointUpdateRequest,
       required: true},
    responses: [
      ok: {"The endpoint", "application/json", Schemas.WebhookEndpointResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such endpoint on this account", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid URL or event filter", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    with {:ok, endpoint} <- fetch(conn, id),
         {:ok, endpoint} <- apply_status(endpoint, params, conn),
         {:ok, endpoint} <-
           Webhooks.update_endpoint(endpoint, endpoint_attrs(params), Audited.attribution(conn)) do
      render(conn, :show, endpoint: endpoint)
    end
  end

  operation(:delete,
    summary: "Delete a webhook endpoint",
    description: "Its delivery log goes with it. Queued deliveries are dropped.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such endpoint on this account", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, endpoint} <- fetch(conn, id),
         {:ok, _} <- Webhooks.delete_endpoint(endpoint, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:rotate,
    summary: "Rotate the signing secret",
    description:
      "Returns a new secret and invalidates the old one immediately. A receiver that " <>
        "verifies signatures has to be updated in the same breath.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok:
        {"The endpoint, with its new secret", "application/json",
         Schemas.WebhookEndpointCreatedResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such endpoint on this account", "application/json", Schemas.Error}
    ]
  )

  def rotate(conn, %{"id" => id}) do
    with {:ok, endpoint} <- fetch(conn, id),
         {:ok, {endpoint, secret}} <- Webhooks.rotate_secret(endpoint, Audited.attribution(conn)) do
      render(conn, :created, endpoint: endpoint, secret: secret)
    end
  end

  operation(:test,
    summary: "Send a test event",
    description:
      "Queues one `webhook.test` delivery, signed like any other. Delivered whatever the " <>
        "endpoint's filter says, and deliberately outside the `conversation.*` namespace " <>
        "so a receiver switching on type cannot mistake it for a real transition.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      accepted: {"Queued", "application/json", Schemas.WebhookTestResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such endpoint on this account", "application/json", Schemas.Error}
    ]
  )

  def test(conn, %{"id" => id}) do
    with {:ok, endpoint} <- fetch(conn, id),
         {:ok, _job} <- Webhooks.deliver_test_event(endpoint) do
      conn
      |> put_status(:accepted)
      |> render(:test, event_type: "webhook.test")
    end
  end

  operation(:deliveries,
    summary: "Recent delivery attempts",
    description:
      "Newest first, one row per HTTP attempt. Pruned on the `webhook_deliveries` " <>
        "retention window (30 days by default).",
    parameters: [
      id: [in: :path, type: :string, required: true],
      limit: [in: :query, type: :integer, required: false, description: "Default 50, max 200."]
    ],
    responses: [
      ok: {"Attempts", "application/json", Schemas.WebhookDeliveryListResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such endpoint on this account", "application/json", Schemas.Error}
    ]
  )

  def deliveries(conn, %{"id" => id} = params) do
    with {:ok, endpoint} <- fetch(conn, id) do
      render(conn, :deliveries, deliveries: Webhooks.list_deliveries(endpoint, limit(params)))
    end
  end

  operation(:redeliver,
    summary: "Send one recorded event again",
    description:
      "A fresh job with a fresh attempt counter, against the endpoint's current URL and " <>
        "current secret. The payload is the one that was recorded.",
    parameters: [
      id: [in: :path, type: :string, required: true],
      delivery_id: [in: :path, type: :string, required: true]
    ],
    responses: [
      accepted: {"Queued", "application/json", Schemas.WebhookTestResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found:
        {"No such endpoint or delivery on this account", "application/json", Schemas.Error}
    ]
  )

  def redeliver(conn, %{"id" => id, "delivery_id" => delivery_id}) do
    user = conn.assigns.current_user

    with {:ok, _endpoint} <- fetch(conn, id),
         %{} = delivery <- Webhooks.get_delivery(delivery_id, user.id),
         {:ok, _job} <- Webhooks.redeliver(delivery) do
      conn
      |> put_status(:accepted)
      |> render(:test, event_type: delivery.event_type)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  ## ── helpers ───────────────────────────────────────────────────────────────

  defp fetch(conn, id) do
    case Webhooks.get_endpoint(id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      endpoint -> {:ok, endpoint}
    end
  end

  # `status` is applied through the context's own enable/disable functions
  # rather than cast as a field: each has bookkeeping (the failure counter,
  # the disabled reason, an audit row of its own) that a field write skips.
  defp apply_status(%{status: "disabled"} = endpoint, %{"status" => "active"}, conn) do
    Webhooks.enable_endpoint(endpoint, Audited.attribution(conn))
  end

  defp apply_status(%{status: "active"} = endpoint, %{"status" => "disabled"}, conn) do
    Webhooks.disable_endpoint(endpoint, "switched off by its owner", Audited.attribution(conn))
  end

  defp apply_status(endpoint, _params, _conn), do: {:ok, endpoint}

  defp endpoint_attrs(params), do: Map.take(params, ["url", "description", "event_types"])

  defp limit(params) do
    case params["limit"] do
      nil -> 50
      value -> value |> to_string() |> Integer.parse() |> clamp()
    end
  end

  defp clamp({n, _}) when n > 0, do: min(n, 200)
  defp clamp(_), do: 50
end
