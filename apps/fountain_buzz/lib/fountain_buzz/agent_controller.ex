defmodule FountainBuzz.AgentController do
  @moduledoc """
  Provision and manage hosted Buzz agents over the API (ADR 0020 Phase 3, #738).

  This is the Fountain-side surface the `buzz-backend-fountain` remote-agents
  provider calls: `create` maps onto a provider `deploy` (idempotent on the
  Nostr pubkey), and `delete` tears the hosted agent down. The Nostr secret key
  is accepted on `create` and stored server-side in the identity's vault; it is
  never returned and never enters a sandbox.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias FountainBuzz, as: Buzz
  alias FountainBuzz.{Identity, Manager}
  alias Fountain.Vaults
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Buzz"])

  operation(:index,
    # Pinned, and deliberately still spelling the module this controller used to
    # be. OpenApiSpex derives operationId from module + action, so the #1507
    # rename would have changed four of them — and ADR 0043 decision 6 promises
    # the published spec keeps its operationIds, because the four SDKs are
    # generated from it (#1411). The id is a wire value; the module name is not.
    operation_id: "FountainWeb.BuzzAgentController.index",
    summary: "List hosted Buzz agents",
    responses: [
      ok: {"Buzz agents", "application/json", FountainBuzz.Schemas.BuzzIdentityListResponse},
      # Declared on every operation here rather than allowlisted, which is what
      # #1536 asked for: the schema guard could not see an extension's responses
      # at all until it learned to resolve through `ExtensionDispatch`, and the
      # core allowlist is the wrong home for an entry a core-only run cannot
      # evaluate. `TenantAPIAuth` runs in the host's `:api` pipeline before the
      # forward, so every operation below can answer 401. Core's own operations
      # are still on the allowlist under #1432; there are 66 of those and 8 here.
      unauthorized: {"Missing or invalid API key", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{data: Enum.map(Buzz.list_identities(user.id), &identity_json/1)})
  end

  operation(:create,
    # Pinned, and deliberately still spelling the module this controller used to
    # be. OpenApiSpex derives operationId from module + action, so the #1507
    # rename would have changed four of them — and ADR 0043 decision 6 promises
    # the published spec keeps its operationIds, because the four SDKs are
    # generated from it (#1411). The id is a wire value; the module name is not.
    operation_id: "FountainWeb.BuzzAgentController.create",
    summary: "Provision (or converge on) a hosted Buzz agent",
    request_body:
      {"Provision attributes", "application/json", FountainBuzz.Schemas.BuzzProvisionRequest},
    description:
      "Converges on the Nostr pubkey, so a provider may call it repeatedly. " <>
        "A deploy that would add a **new** hosted agent is gated by the credit " <>
        "balance and by `BUZZ_IDENTITY_CEILING`, both `402`; a converging " <>
        "deploy of an agent that already exists is not.",
    responses: [
      created: {"Buzz agent", "application/json", FountainBuzz.Schemas.BuzzIdentityResponse},
      payment_required:
        {"Balance exhausted, or the hosted-agent ceiling is reached", "application/json",
         Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      # `environment_id` naming an environment that does not exist, or belongs
      # to somebody else. Undeclared until #1536 taught the schema guard to see
      # this extension at all, and then found it on the first run.
      not_found: {"The named environment does not exist", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid API key", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs =
      Map.take(
        params,
        ~w(name relay_url agent_id pubkey private_key_nsec auth_tag display_name environment_id
           sandbox_mode respond_to respond_to_allowlist)
      )

    # A converging deploy may change what the harness was launched with; the
    # identity as it was before tells us whether the running one must bounce.
    before = Buzz.get_identity_by_pubkey(params["pubkey"] || "", user.id)

    case Buzz.provision_identity(user.id, attrs, actor: "api") do
      {:ok, %Identity{} = identity} ->
        # Best-effort eager start so a provider `deploy` sees it running; the
        # boot sweep also stands enabled identities up, so this is not load-bearing.
        # When the deploy changed a launch-relevant field (author gate, environment,
        # relay, name — #790) the harness restarts so the new env takes effect.
        _ = ensure_harness(before, identity)

        conn
        |> put_status(:created)
        |> json(%{data: identity_json(identity)})

      {:error, {:missing, fields}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "missing required fields: #{Enum.join(fields, ", ")}"})

      # 404 like every other unknown-or-foreign environment id, so the response
      # cannot be used to probe which ids exist.
      {:error, :environment_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "environment_not_found"})

      {:error, :invalid_sandbox_mode} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "invalid_sandbox_mode",
          detail: "sandbox_mode must be ephemeral or persistent"
        })

      # 402, the same status the credit gate uses, and for the same reason:
      # the fix is a top-up or an operator decision, not a retry. The numbers are in the body so a provider can say which
      # ceiling it hit (#1017).
      {:error, {:identity_limit_reached, %{count: count, limit: limit}}} ->
        conn
        |> put_status(:payment_required)
        |> json(%{
          error: "identity_limit_reached",
          message: "this account may run #{limit} hosted Buzz agents (#{count} in use)",
          count: count,
          limit: limit
        })

      # Standing up a permanent process is spend, so the balance gates it
      # (ADR 0031). Rendered by the FallbackController as the 402 every other
      # door gives, with `upgrade_url`.
      {:error, :insufficient_credits} = err ->
        err

      # Field errors — an empty allowlist in allowlist mode, a malformed pubkey —
      # so a provider deploy can say *why* it was refused, not a bare 422.
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "could not provision the buzz agent"})
    end
  end

  operation(:update,
    # Pinned, and deliberately still spelling the module this controller used to
    # be. OpenApiSpex derives operationId from module + action, so the #1507
    # rename would have changed four of them — and ADR 0043 decision 6 promises
    # the published spec keeps its operationIds, because the four SDKs are
    # generated from it (#1411). The id is a wire value; the module name is not.
    operation_id: "FountainWeb.BuzzAgentController.update",
    summary: "Change who may talk to a hosted Buzz agent",
    parameters: [id: [in: :path, type: :string, description: "Buzz agent id"]],
    request_body:
      {"Access attributes", "application/json", FountainBuzz.Schemas.BuzzAccessUpdateRequest},
    responses: [
      ok: {"Buzz agent", "application/json", FountainBuzz.Schemas.BuzzIdentityResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid API key", "application/json", Schemas.Error}
    ]
  )

  # The operator's knob for the inbound author gate (#790): sets `respond_to`
  # / `respond_to_allowlist` on the identity and restarts its harness so the
  # new gate is live. Exists because the desktop refuses to change access on a
  # provider agent it has already deployed, so the record's policy cannot be
  # resent from there. Harness-side only: the desktop's owner-signed kind-30177
  # policy is what other users' clients (Desktop >= 0.5.17) trust for
  # mentionability, and this does not touch it — see `Buzz.update_access/3`
  # and #820.
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %Identity{} = identity <- Buzz.get_identity(id, user.id),
         {:ok, %Identity{} = updated} <-
           Buzz.update_access(identity, Map.take(params, ~w(respond_to respond_to_allowlist)),
             actor: "api"
           ) do
      if Buzz.launch_config_changed?(identity, updated), do: Manager.restart_harness(updated)
      json(conn, %{data: identity_json(updated)})
    else
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :nothing_to_update} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "nothing to update: send respond_to and/or respond_to_allowlist"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  operation(:delete,
    # Pinned, and deliberately still spelling the module this controller used to
    # be. OpenApiSpex derives operationId from module + action, so the #1507
    # rename would have changed four of them — and ADR 0043 decision 6 promises
    # the published spec keeps its operationIds, because the four SDKs are
    # generated from it (#1411). The id is a wire value; the module name is not.
    operation_id: "FountainWeb.BuzzAgentController.delete",
    summary: "Tear down a hosted Buzz agent",
    parameters: [id: [in: :path, type: :string, description: "Buzz agent id"]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid API key", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Buzz.get_identity(id, user.id) do
      %Identity{} = identity ->
        Manager.stop_harness(identity.id)
        {:ok, _} = Buzz.delete_identity(identity, actor: "api")
        delete_vault(identity, user.id)
        send_resp(conn, :no_content, "")

      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  defp ensure_harness(%Identity{} = before, %Identity{} = identity) do
    if Buzz.launch_config_changed?(before, identity),
      do: Manager.restart_harness(identity),
      else: Manager.start_harness(identity)
  end

  defp ensure_harness(nil, %Identity{} = identity), do: Manager.start_harness(identity)

  defp delete_vault(%Identity{vault_id: vault_id}, user_id) do
    with %Vaults.Vault{} = vault <- Vaults.get_vault(vault_id, user_id),
         # A home built on this vault is retired first, and a running turn on
         # one refuses the delete (#1084). The harness is stopped above, so
         # this is a turn some other conversation is running on the same
         # machine; the identity still goes and the vault is left for the
         # owner rather than failing the request.
         {:error, reason} <- Vaults.delete_vault(vault, actor: "api") do
      Logger.warning(
        "buzz identity deleted but its vault #{vault_id} was kept: #{inspect(reason)}"
      )
    end

    :ok
  end

  defp identity_json(%Identity{} = i) do
    %{
      id: i.id,
      name: i.name,
      display_name: i.display_name,
      relay_url: i.relay_url,
      pubkey: i.pubkey,
      agent_id: i.agent_id,
      vault_id: i.vault_id,
      environment_id: i.environment_id,
      sandbox_mode: i.sandbox_mode,
      respond_to: i.respond_to,
      respond_to_allowlist: i.respond_to_allowlist,
      enabled: i.enabled,
      inserted_at: i.inserted_at,
      updated_at: i.updated_at
    }
  end
end
