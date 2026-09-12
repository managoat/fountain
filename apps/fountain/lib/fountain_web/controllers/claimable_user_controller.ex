defmodule FountainWeb.ClaimableUserController do
  @moduledoc """
  Claimable principals (ADR 0044, #1551).

      POST   /api/claimable-users            — open one
      GET    /api/claimable-users/:id        — reconcile
      POST   /api/claimable-users/:id/claim  — attach an owner
      DELETE /api/claimable-users/:id        — abandon it

  Every route is full-scope. That is what keeps a principal out of its own
  grant surface: a `principal`-scoped key cannot open a second principal,
  enumerate anyone else's, claim itself, or release the grant that bounds it.

  `Idempotency-Key` is read from the header on create and claim. Both replay:
  the same key returns the same principal rather than a second one, with a
  fresh credential, because the secret from the first response was never
  stored.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Principals
  alias Fountain.Principals.ClaimableUser
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  @provider_strings Enum.map(Fountain.InferenceCredentials.Credential.providers(), &to_string/1)

  tags(["Claimable principals"])

  operation(:create,
    summary: "Open a claimable principal",
    description:
      "Creates an anonymous tenant an application can build a computer inside " <>
        "before its visitor has a Fountain account, and returns a scoped API key " <>
        "for it plus a one-time claim token. The principal is funded out of the " <>
        "calling account's credit balance and expires on its own. Send an " <>
        "`Idempotency-Key` header: replaying it returns the same principal with a " <>
        "fresh key and claim token.",
    parameters: [
      "Idempotency-Key": [
        in: :header,
        type: :string,
        required: false,
        description: "Replay-safe creation key, unique per application."
      ]
    ],
    request_body:
      {"Grant", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           application_id: %OpenApiSpex.Schema{
             type: :string,
             description: "The application's own label for itself, for the audit trail."
           },
           expires_in: %OpenApiSpex.Schema{
             type: :integer,
             description:
               "Seconds until the principal expires. Clamped to the deployment's maximum."
           },
           limits: %OpenApiSpex.Schema{
             type: :object,
             properties: %{
               max_live_sandboxes: %OpenApiSpex.Schema{type: :integer},
               max_cost_usd: %OpenApiSpex.Schema{type: :number}
             }
           },
           metadata: %OpenApiSpex.Schema{type: :object}
         },
         required: [:application_id]
       }},
    responses: [
      created: {"Opened", "application/json", Schemas.ClaimableUserCreatedResponse},
      bad_request: {"Malformed grant", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Not a full-scope key", "application/json", Schemas.Error},
      payment_required: {"The application cannot fund it", "application/json", Schemas.Error},
      too_many_requests: {"Too many principals, or too fast", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    application = conn.assigns.current_user
    opts = Keyword.put(Audited.attribution(conn), :idempotency_key, idempotency_key(conn))

    with {:ok, result} <- Principals.create_claimable(application, params, opts) do
      conn
      |> put_status(:created)
      |> render(:created, result)
    end
  end

  operation(:show,
    summary: "Read a claimable principal",
    description:
      "The grant's current status, for an application recovering from a lost " <>
        "response. Readable by the application that opened it and by the account " <>
        "that claimed it; anyone else gets 404, so an id cannot be probed.",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "The grant's id."]
    ],
    responses: [
      ok: {"The grant", "application/json", Schemas.ClaimableUserResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such grant", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Principals.get_claimable_for(id, user.id) do
      nil -> {:error, :not_found}
      %ClaimableUser{} = claimable -> render(conn, :show, claimable: claimable)
    end
  end

  operation(:claim,
    summary: "Claim a principal",
    description:
      "Attaches the calling account as the principal's owner and returns a fresh " <>
        "credential for it. Nothing about the machine changes: the sandbox, agent, " <>
        "environment, vault, conversations and every id survive the claim. The " <>
        "credential the application held is revoked in the same transaction. A " <>
        "brand-new account and an account that already owns other principals claim " <>
        "the same way.",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "The grant's id."],
      "Idempotency-Key": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Replaying a successful claim with this key and the same account returns " <>
            "the same outcome with a fresh credential."
      ]
    ],
    request_body:
      {"Claim", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{claim_token: %OpenApiSpex.Schema{type: :string}},
         required: [:claim_token]
       }},
    responses: [
      ok: {"Claimed", "application/json", Schemas.ClaimedPrincipalResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden:
        {"Bad claim token, or an account that cannot claim", "application/json", Schemas.Error},
      not_found: {"No such grant", "application/json", Schemas.Error},
      conflict: {"Already claimed", "application/json", Schemas.Error},
      gone: {"Expired or released", "application/json", Schemas.Error}
    ]
  )

  def claim(conn, %{"id" => id} = params) do
    claimer = conn.assigns.current_user
    opts = Keyword.put(Audited.attribution(conn), :idempotency_key, idempotency_key(conn))
    token = Map.get(params, "claim_token")

    with {:ok, result} <- Principals.claim(id, token, claimer, opts) do
      render(conn, :claimed, Map.put(result, :user, claimer))
    end
  end

  operation(:delete,
    summary: "Abandon a claimable principal",
    description:
      "Revokes the principal's credentials, destroys its sandboxes and refunds " <>
        "what its introductory grant still holds. The grant stays readable so a " <>
        "lost response can still be reconciled; the principal itself is deleted a " <>
        "retention window later. A claimed principal belongs to the account that " <>
        "claimed it and cannot be released this way.",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "The grant's id."]
    ],
    responses: [
      no_content: "Released",
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such grant", "application/json", Schemas.Error},
      conflict: {"Already claimed", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    application = conn.assigns.current_user

    # Scoped read first, and the application's own view of it: an account that
    # merely claimed a principal reads the grant through `show` but is not the
    # one who can abandon it.
    case Principals.get_claimable_for(id, application.id) do
      %ClaimableUser{application_user_id: app_id} = claimable when app_id == application.id ->
        with {:ok, _} <- Principals.release(claimable, Audited.attribution(conn)) do
          send_resp(conn, :no_content, "")
        end

      _ ->
        {:error, :not_found}
    end
  end

  operation(:put_inference_credential,
    summary: "Set a provider credential on a principal",
    description:
      "Stores the credential encrypted under the principal's own tenant key. " <>
        "A principal is a first-class tenant and a `principal`-scoped key cannot " <>
        "write account state, so this is how the application that opened it (or " <>
        "the account that claimed it) puts a customer's inference key on it. The " <>
        "principal's own credential gains nothing from this route.",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "The grant's id."],
      provider: [
        in: :path,
        type: %OpenApiSpex.Schema{type: :string, enum: @provider_strings},
        required: true
      ]
    ],
    request_body: {"Credential", "application/json", Schemas.InferenceCredentialRequest},
    responses: [
      no_content: "Stored",
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Not a full-scope key", "application/json", Schemas.Error},
      not_found: {"No such grant", "application/json", Schemas.Error},
      unprocessable_entity: {"Blank value or unknown provider", "application/json", Schemas.Error}
    ]
  )

  def put_inference_credential(conn, %{"id" => id, "provider" => provider_str} = params) do
    value = params |> Map.get("value") |> to_trimmed_string()

    with {:ok, provider} <- parse_provider(provider_str),
         :ok <- reject_empty(value),
         {:ok, _} <- write_principal_credential(conn, id, provider, value) do
      send_resp(conn, :no_content, "")
    else
      {:error, :empty_value} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "value is required", reason: "empty_value"})

      other ->
        other
    end
  end

  operation(:delete_inference_credential,
    summary: "Clear a provider credential on a principal",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "The grant's id."],
      provider: [
        in: :path,
        type: %OpenApiSpex.Schema{type: :string, enum: @provider_strings},
        required: true
      ]
    ],
    responses: [
      no_content: "Cleared",
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"Not a full-scope key", "application/json", Schemas.Error},
      not_found: {"No such grant", "application/json", Schemas.Error},
      unprocessable_entity: {"Unknown provider", "application/json", Schemas.Error}
    ]
  )

  def delete_inference_credential(conn, %{"id" => id, "provider" => provider_str}) do
    with {:ok, provider} <- parse_provider(provider_str),
         {:ok, _} <- write_principal_credential(conn, id, provider, nil) do
      send_resp(conn, :no_content, "")
    end
  end

  # No provider ping here, unlike the account's own route. The value belongs
  # to somebody the operator is acting for, the principal may be short-lived,
  # and a validation call would spend that customer's quota on a request they
  # did not make. The application validated it wherever it collected it.
  defp write_principal_credential(conn, id, provider, value) do
    Principals.put_inference_credential(
      id,
      conn.assigns.current_user.id,
      provider,
      value,
      Audited.attribution(conn)
    )
  end

  # The path parameter is an enum in the spec, so an unknown provider is a 422
  # before the action runs. This is the fail-closed backstop.
  defp parse_provider(provider_str) when provider_str in @provider_strings do
    {:ok, String.to_existing_atom(provider_str)}
  end

  defp parse_provider(_), do: {:error, :not_found}

  defp reject_empty(""), do: {:error, :empty_value}
  defp reject_empty(nil), do: {:error, :empty_value}
  defp reject_empty(_), do: :ok

  defp to_trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp to_trimmed_string(_), do: nil

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key | _] when byte_size(key) > 0 -> String.slice(key, 0, 200)
      _ -> nil
    end
  end
end
