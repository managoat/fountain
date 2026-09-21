defmodule FountainWeb.ChatGPTSubscriptionController do
  @moduledoc """
  An account's ChatGPT subscriptions and the sign-ins that link them, over
  the API (ADR 0060 decision 3).

  A subscription is a grant in `Fountain.ChatGPTAccounts`: Fountain holds and
  renews its tokens and a credential set names it by id
  (`FountainWeb.InferenceCredentialSetController`). Linking is a device-code
  sign-in that takes a person minutes, so it is a resource of its own: create
  an attempt, show its code, read it until it ends. The server polls ChatGPT;
  a client only ever reads the attempt's row. There is no endpoint that
  returns or refreshes a token, and there never will be one here.

  Behind `:require_full_scope` like every other account-level write: a
  sandbox's per-conversation token can neither start a link nor see one.
  Every read is scoped by the caller, so another account's subscription or
  attempt is a 404, never a 403.

  Only one door is gated. Creating an attempt for a **new** subscription
  answers 404 `chatgpt_subscriptions_not_enabled` unless
  `Fountain.ChatGPTAccounts.linking_enabled_for?/1`, which is the broker and
  the `chatgpt_subscriptions` rollout flag; a reconnect needs the broker
  alone. Listing, renaming, disconnecting, removing, and reading or
  cancelling an attempt ask neither, so turning linking off strands nothing.
  `/api/auth/me` reports the gate as `chatgpt_subscriptions_enabled`, and so
  does the list, as `linking_enabled`.

  An attempt's body carries a user code while it is pending, so those
  responses are `cache-control: no-store`.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.ChatGPTAccounts
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  # A sign-in costs the auth server a device code. The pending limit bounds
  # how many are open; this bounds how fast one key can churn through them.
  plug FountainWeb.Plugs.RateLimit,
       [bucket: "chatgpt_link", max: 10, window_ms: 3_600_000, key: :api_key]
       when action in [:create_attempt]

  plug :no_store when action in [:create_attempt, :index_attempts, :show_attempt, :cancel_attempt]

  tags(["ChatGPT subscriptions"])

  operation(:index,
    summary: "List ChatGPT subscriptions",
    description:
      "Every subscription the account holds, by name, with how many it may hold and " <>
        "whether it may link another now. Tokens are never returned.",
    responses: [
      ok: {"Subscriptions", "application/json", Schemas.ChatGPTSubscriptionListResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user

    render(conn, :index,
      grants: ChatGPTAccounts.list_for_user(user.id),
      limit: ChatGPTAccounts.grant_ceiling(),
      linking_enabled: ChatGPTAccounts.linking_enabled_for?(user.id)
    )
  end

  operation(:update,
    summary: "Rename a ChatGPT subscription",
    description:
      "A name is a label. Renaming changes no credential, and conversations running " <>
        "on the subscription are not disturbed.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"New name", "application/json", Schemas.ChatGPTSubscriptionUpdateRequest},
    responses: [
      ok: {"Subscription", "application/json", Schemas.ChatGPTSubscriptionResponse},
      forbidden:
        {"Insufficient scope, or `chatgpt_owner_ineligible`", "application/json", Schemas.Error},
      not_found: {"No such subscription", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid or duplicate name", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, grant} <-
           tagged(
             ChatGPTAccounts.rename_for_user(
               id,
               user.id,
               name_param(params),
               Audited.attribution(conn)
             )
           ) do
      render(conn, :show, grant: grant)
    end
  end

  operation(:disconnect,
    summary: "Disconnect a ChatGPT subscription",
    description:
      "Forgets the subscription's tokens and keeps its row. From the moment this " <>
        "returns no sandbox request may use it, inside a connection that was already " <>
        "open too. A credential set that names it keeps naming it, and its codex runs " <>
        "fail by name until the subscription is reconnected or the set is pointed " <>
        "elsewhere; nothing is substituted. Already disconnected is a 200. The token " <>
        "is not revoked at ChatGPT.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Subscription", "application/json", Schemas.ChatGPTSubscriptionResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such subscription", "application/json", Schemas.Error}
    ]
  )

  def disconnect(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with :ok <- ChatGPTAccounts.disconnect_for_user(id, user.id, Audited.attribution(conn)),
         {:ok, grant} <- ChatGPTAccounts.get_for_user(id, user.id) do
      render(conn, :show, grant: grant)
    end
  end

  operation(:delete,
    summary: "Remove a disconnected ChatGPT subscription",
    description:
      "Deletes the row, which frees its place under the limit. Refused with 409 " <>
        "`chatgpt_grant_still_connected` until it is disconnected, and with 409 " <>
        "`chatgpt_grant_named_by_sets` while credential sets name it.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Removed",
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such subscription", "application/json", Schemas.Error},
      conflict: {"Still connected, or named by sets", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with :ok <- tagged(ChatGPTAccounts.remove_for_user(id, user.id, Audited.attribution(conn))) do
      send_resp(conn, :no_content, "")
    end
  end

  operation(:create_attempt,
    summary: "Start a ChatGPT sign-in",
    description:
      "`name` links a new subscription; `grant_id` reconnects one, which keeps the " <>
        "old credential serving until the new sign-in commits. The answer carries the " <>
        "code to type and the page to type it on. It expires in fifteen minutes. " <>
        "Limited to ten an hour per API key and three open at once per account.",
    request_body:
      {"What to sign in for", "application/json", Schemas.ChatGPTLinkAttemptCreateRequest},
    responses: [
      created: {"Attempt", "application/json", Schemas.ChatGPTLinkAttemptResponse},
      forbidden:
        {"Insufficient scope, or `chatgpt_owner_ineligible`", "application/json", Schemas.Error},
      not_found:
        {"`chatgpt_subscriptions_not_enabled`, or no such subscription to reconnect",
         "application/json", Schemas.Error},
      conflict:
        {"`chatgpt_grant_limit_reached`, `chatgpt_link_attempts_exceeded` or " <>
           "`chatgpt_link_attempt_pending`", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid or duplicate name", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error},
      bad_gateway: {"`chatgpt_auth_unreachable`", "application/json", Schemas.Error},
      service_unavailable: {"`chatgpt_tenant_key_unavailable`", "application/json", Schemas.Error}
    ]
  )

  def create_attempt(conn, params) do
    user = conn.assigns.current_user

    with {:ok, attempt} <-
           tagged(
             ChatGPTAccounts.start_attempt_for_user(
               user.id,
               target(params),
               Audited.attribution(conn)
             )
           ) do
      conn
      |> put_status(:created)
      |> render(:attempt, attempt: attempt)
    end
  end

  operation(:index_attempts,
    summary: "List open ChatGPT sign-ins",
    description:
      "The account's pending attempts, oldest first, each with its code: what a " <>
        "client that lost its state reads to pick up where it was.",
    responses: [
      ok: {"Attempts", "application/json", Schemas.ChatGPTLinkAttemptListResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index_attempts(conn, _params) do
    attempts = ChatGPTAccounts.list_pending_attempts_for_user(conn.assigns.current_user.id)
    render(conn, :attempts, attempts: attempts)
  end

  operation(:show_attempt,
    summary: "Read a ChatGPT sign-in",
    description:
      "The endpoint to poll. It reads a row and contacts nobody. An attempt that ran " <>
        "out of time reads `expired`.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Attempt", "application/json", Schemas.ChatGPTLinkAttemptResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such attempt", "application/json", Schemas.Error}
    ]
  )

  def show_attempt(conn, %{"id" => id}) do
    with {:ok, attempt} <-
           ChatGPTAccounts.get_attempt_for_user(id, conn.assigns.current_user.id) do
      render(conn, :attempt, attempt: attempt)
    end
  end

  operation(:cancel_attempt,
    summary: "Cancel a ChatGPT sign-in",
    description:
      "Ends a pending attempt; a sign-in approved afterwards stores nothing. Already " <>
        "cancelled is a 200. An attempt that has completed, failed or expired is a 409 " <>
        "`chatgpt_link_attempt_not_pending` carrying its `state`.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Attempt", "application/json", Schemas.ChatGPTLinkAttemptResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such attempt", "application/json", Schemas.Error},
      conflict: {"`chatgpt_link_attempt_not_pending`", "application/json", Schemas.Error}
    ]
  )

  def cancel_attempt(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, attempt} <-
           ChatGPTAccounts.cancel_attempt_for_user(id, user.id, Audited.attribution(conn)) do
      render(conn, :attempt, attempt: attempt)
    end
  end

  ## Private

  defp name_param(%{"name" => name}) when is_binary(name), do: name
  defp name_param(_params), do: ""

  # Exactly one of the two, or the context is handed something it refuses.
  defp target(%{"name" => name, "grant_id" => grant_id})
       when is_binary(name) and is_binary(grant_id),
       do: %{}

  defp target(%{"name" => name}) when is_binary(name), do: %{name: name}
  defp target(%{"grant_id" => grant_id}) when is_binary(grant_id), do: %{grant_id: grant_id}
  defp target(_params), do: %{}

  # The context's bare atoms say too little for `FallbackController` to match
  # on their own (`:still_connected`, `:ineligible_owner`), so they go there
  # tagged. `:not_found`, tuples and changesets already say what they are.
  defp tagged({:error, reason}) when is_atom(reason) and reason != :not_found,
    do: {:error, {:chatgpt_subscription, reason}}

  defp tagged(result), do: result

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")
end
