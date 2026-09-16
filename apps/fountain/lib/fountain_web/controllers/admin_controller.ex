defmodule FountainWeb.AdminController do
  @moduledoc """
  Operator surface over the API (#527).

  Every admin operation was `AdminLive`-only, so nothing could be scripted: a
  bulk credit grant, a suspension from an incident runbook, a nightly export
  of the privilege trail all meant a human clicking. This mirrors the LiveView's
  actions one-for-one, including its refusals.

  Three things are carried over deliberately:

    * the same self-action refusals — no suspending or deleting yourself, and
      (new here) no revoking your own admin role, which over an API is a
      lockout one typo away rather than a button you can see;
    * billing actions refuse when `credits_enabled` is false, because they talk
      to Stripe;
    * the same `admin.*` privilege-trail events, so an action taken with curl
      is as visible as one taken with a mouse.

  Cross-tenant reads stay metadata-only, the `ConversationDetail` principle:
  prompt and output content never cross a tenant boundary, whatever the role.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Accounts, Audit, Billing, Conversations, Quotas}
  alias Fountain.Accounts.Deletion
  alias Fountain.Conversations.Termination
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  @default_per_page 25
  @max_per_page 100

  tags(["Admin"])

  ## ── users ────────────────────────────────────────────────────────────────

  operation(:index_users,
    summary: "List accounts (admin)",
    parameters: [
      q: [in: :query, type: :string, required: false, description: "Email substring."],
      comped: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Only comped accounts (`true`) or only billed ones (`false`)."
      ],
      role: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, enum: ~w(admin user)},
        required: false
      ],
      verified: [in: :query, type: :boolean, required: false],
      sort: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, enum: ~w(email joined last_activity)},
        required: false
      ],
      dir: [
        in: :query,
        type: %OpenApiSpex.Schema{type: :string, enum: ~w(asc desc)},
        required: false
      ],
      page: [in: :query, type: :integer, required: false],
      per_page: [
        in: :query,
        type: :integer,
        required: false,
        description: "1..#{@max_per_page}, default #{@default_per_page}."
      ]
    ],
    responses: [
      unprocessable_entity: {"Invalid request parameters", "application/json", Schemas.Error},
      ok: {"Accounts", "application/json", Schemas.AdminUserListResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error}
    ]
  )

  def index_users(conn, params) do
    page = parse_int(params["page"], 1) |> max(1)
    per_page = parse_int(params["per_page"], @default_per_page) |> max(1) |> min(@max_per_page)

    %{users: users, total: total} =
      Accounts.list_users_admin(
        search: params["q"] || "",
        comped: parse_verified(params["comped"]),
        role: if(params["role"] in ~w(admin user), do: params["role"]),
        verified: parse_verified(params["verified"]),
        sort: params["sort"],
        dir: params["dir"] || "desc",
        page: page,
        per_page: per_page
      )

    render(conn, :index_users,
      users: users,
      sandbox_counts: Quotas.active_sandbox_counts(),
      page: page,
      per_page: per_page,
      total: total
    )
  end

  operation(:show_user,
    summary: "Get one account (admin)",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Account", "application/json", Schemas.AdminUserResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show_user(conn, %{"id" => id}) do
    with_user(conn, id, fn user ->
      # ownership: admin surface — the :require_admin_api pipeline established
      # the caller's role before this action ran; cross-tenant reads are the
      # point of the endpoint.
      render(conn, :show_user,
        user: user,
        sandbox_counts: Quotas.active_sandbox_counts(),
        admin_events: Audit._unsafe_list_admin_events_for_target(user.id, 50)
      )
    end)
  end

  operation(:set_role,
    summary: "Grant or revoke the admin role",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Role", "application/json", Schemas.AdminRoleRequest},
    responses: [
      ok: {"Account", "application/json", Schemas.AdminUserResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error}
    ]
  )

  def set_role(conn, %{"id" => id, "role" => role}) when role in ~w(admin user) do
    admin = conn.assigns.current_user

    cond do
      id == admin.id ->
        # Not a rule the LiveView has, because there the toggle is in front of
        # you. Over an API, revoking your own role is a lockout one scripted
        # typo away, recoverable only with a release task.
        refuse(conn, "cannot_change_own_role", "Change your own role from another admin account.")

      true ->
        with_user(conn, id, fn user -> apply_role(conn, admin, user, role) end)
    end
  end

  def set_role(conn, _params),
    do: refuse(conn, "invalid_role", ~s(role must be "admin" or "user".))

  operation(:set_sandbox_limit,
    summary: "Set an account's concurrent-sandbox cap",
    description:
      "The only lever for a noisy or abusive tenant (ADR 0005). 0 stops the " <>
        "account from starting new conversations without suspending it.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Limit", "application/json", Schemas.AdminSandboxLimitRequest},
    responses: [
      ok: {"Account", "application/json", Schemas.AdminUserResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error}
    ]
  )

  def set_sandbox_limit(conn, %{"id" => id, "limit" => limit})
      when is_nil(limit) or (is_integer(limit) and limit >= 0) do
    admin = conn.assigns.current_user

    with_user(conn, id, fn user ->
      case Accounts.update_sandbox_limit(user, limit, actor: "admin") do
        {:ok, updated} ->
          record_admin(admin, user, "admin.sandbox_limit.changed", %{
            "email" => user.email,
            "from" => user.sandbox_limit_override,
            "to" => limit
          })

          render_user(conn, updated)

        {:error, _} ->
          refuse(conn, "invalid_limit", "Limit must be a whole number of 0 or more.")
      end
    end)
  end

  def set_sandbox_limit(conn, _params),
    do:
      refuse(
        conn,
        "invalid_limit",
        "Limit must be a whole number of 0 or more, or null for the balance rule's cap."
      )

  operation(:set_comp,
    summary: "Comp or un-comp an account",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Comped", "application/json", Schemas.AdminCompRequest},
    responses: [
      ok: {"Account", "application/json", Schemas.AdminUserResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error}
    ]
  )

  def set_comp(conn, %{"id" => id, "comped" => comped}) when is_boolean(comped) do
    admin = conn.assigns.current_user

    with :ok <- require_billing() do
      with_user(conn, id, fn user -> apply_comp(conn, admin, user, comped) end)
    end
  end

  def set_comp(conn, _params),
    do: refuse(conn, "invalid_request", "Send {\"comped\": true} or {\"comped\": false}.")

  operation(:grant_credits,
    summary: "Add prepaid credit to an account",
    description:
      "A `grant_admin` ledger row (ADR 0030): goodwill, a won dispute, an " <>
        "outage. It never expires and is spent after the opening grant. There " <>
        "is deliberately no negative form here; a clawback is what a refund " <>
        "or dispute does through Stripe.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Credit", "application/json", Schemas.AdminCreditsRequest},
    responses: [
      ok: {"Account", "application/json", Schemas.AdminUserResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error}
    ]
  )

  def grant_credits(conn, %{"id" => id, "cents" => cents} = params)
      when is_integer(cents) and cents > 0 do
    admin = conn.assigns.current_user
    note = params["note"]

    with :ok <- require_billing() do
      with_user(conn, id, fn user ->
        case Fountain.Credits.grant(user.id, cents, "grant_admin",
               idempotency_key: "grant_admin:#{Ecto.UUID.generate()}",
               actor: "admin:#{admin.id}",
               metadata: %{"note" => note}
             ) do
          {:ok, entry} ->
            record_admin(admin, user, "admin.credits.granted", %{
              "email" => user.email,
              "cents" => cents,
              "note" => note,
              "ledger_entry_id" => entry.id
            })

            render_user(conn, Accounts.get_user(user.id))

          {:error, _} ->
            refuse(conn, "invalid_request", "Could not write the credit.")
        end
      end)
    end
  end

  def grant_credits(conn, _params),
    do:
      refuse(conn, "invalid_request", "Send {\"cents\": <positive integer>, \"note\": \"...\"}.")

  operation(:set_suspended,
    summary: "Suspend or unsuspend an account",
    description:
      "The reversible lever between comp and delete (#287): sessions die, API " <>
        "keys refuse, sandboxes are reaped. Billing is deliberately untouched.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Suspended", "application/json", Schemas.AdminSuspendRequest},
    responses: [
      ok: {"Account", "application/json", Schemas.AdminUserResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error}
    ]
  )

  def set_suspended(conn, %{"id" => id, "suspended" => suspended}) when is_boolean(suspended) do
    admin = conn.assigns.current_user

    if id == admin.id do
      refuse(conn, "cannot_suspend_self", "You cannot suspend your own account.")
    else
      with_user(conn, id, fn user -> apply_suspend(conn, admin, user, suspended) end)
    end
  end

  def set_suspended(conn, _params),
    do: refuse(conn, "invalid_request", "Send {\"suspended\": true} or {\"suspended\": false}.")

  operation(:delete_user,
    summary: "Delete an account (admin)",
    description:
      "The support path for a deletion request that cannot go through the " <>
        "account page — a locked-out user, or one who asked by email. Same " <>
        "teardown as self-serve; only the recorded actor differs.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.AccountDeletedResponse},
      bad_gateway: {"Billing cancellation failed", "application/json", Schemas.Error},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Refused", "application/json", Schemas.Error}
    ]
  )

  def delete_user(conn, %{"id" => id}) do
    admin = conn.assigns.current_user

    if id == admin.id do
      refuse(
        conn,
        "cannot_delete_self",
        "Delete your own account through DELETE /api/account."
      )
    else
      with_user(conn, id, fn user -> apply_delete(conn, admin, user) end)
    end
  end

  ## ── sandboxes ────────────────────────────────────────────────────────────

  operation(:index_sandboxes,
    summary: "List live sandboxes across all tenants",
    responses: [
      ok: {"Sandboxes", "application/json", Schemas.AdminSandboxListResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error}
    ]
  )

  def index_sandboxes(conn, _params) do
    # ownership: admin surface — :require_admin_api gated this request.
    render(conn, :index_sandboxes, sandboxes: Conversations._unsafe_list_sandboxes_admin())
  end

  operation(:reap_sandbox,
    summary: "Reap a sandbox",
    description:
      "`terminated` when live conversations were ended with it, `released` " <>
        "when the sprite went and the conversations stay resumable, " <>
        "`already_terminal` when there was nothing to do.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Outcome", "application/json", Schemas.AdminReapResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error},
      service_unavailable:
        {"Another teardown holds this machine; retry", "application/json", Schemas.Error}
    ]
  )

  def reap_sandbox(conn, %{"id" => id}) do
    admin = conn.assigns.current_user

    # ownership: admin surface — :require_admin_api gated this request. Reaping
    # is cross-tenant by nature; the sandbox is identified by id alone.
    # Termination.reap_sandbox/2 records admin.sandbox.reaped itself (#2255
    # decision 4).
    case Termination.reap_sandbox(id, admin_user_id: admin.id) do
      {:ok, outcome} ->
        json(conn, %{data: %{sandbox_id: id, outcome: to_string(outcome)}})

      # `:not_found` and, since ADR 0058 stage 5b, `:sandbox_unavailable` —
      # the machine's owner is busy with another destroy of it, which is
      # ordinary contention between an operator's reap and the reaper's own
      # expiry. `FallbackController` renders it as the 503 with `retry-after`
      # it renders everywhere else, which is why the refusal is passed through
      # rather than matched: a clause per word here would drift from the
      # `Machine.destroy/2` spec the next stage widens.
      {:error, _reason} = error ->
        error
    end
  end

  ## ── trails ───────────────────────────────────────────────────────────────

  operation(:index_audit,
    summary: "Cross-tenant audit events",
    description:
      "Every tenant's events, newest first — the unscoped view behind `/audit` " <>
        "for admins. Use `GET /api/audit` for the caller's own trail.",
    parameters: [
      limit: [in: :query, type: :integer, required: false, description: "1..500, default 100."]
    ],
    responses: [
      ok: {"Audit events", "application/json", Schemas.AdminAuditListResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error}
    ]
  )

  def index_audit(conn, params) do
    limit = parse_int(params["limit"], 100) |> max(1) |> min(500)
    # ownership: admin surface — :require_admin_api gated this request. This is
    # the cross-tenant view; GET /api/audit is the tenant-scoped one.
    render(conn, :index_audit, events: Audit._unsafe_list_recent(limit))
  end

  operation(:index_admin_events,
    summary: "The privilege trail",
    description:
      "Administrative actions taken against accounts — who did what to whom. " <>
        "Separate from the audit trail because these carry both an actor and a " <>
        "target.",
    parameters: [
      limit: [in: :query, type: :integer, required: false, description: "1..500, default 100."]
    ],
    responses: [
      ok: {"Admin events", "application/json", Schemas.AdminEventListResponse},
      forbidden: {"Admin required", "application/json", Schemas.Error}
    ]
  )

  def index_admin_events(conn, params) do
    limit = parse_int(params["limit"], 100) |> max(1) |> min(500)
    # ownership: admin surface — :require_admin_api gated this request.
    render(conn, :index_admin_events, events: Audit._unsafe_list_recent_admin(limit))
  end

  ## ── action bodies ────────────────────────────────────────────────────────

  defp apply_role(conn, admin, user, role) do
    case Accounts.update_user_role(user, role, actor: "admin") do
      {:ok, updated} ->
        record_admin(
          admin,
          user,
          if(role == "admin", do: "admin.role.granted", else: "admin.role.revoked"),
          %{"email" => user.email, "from" => user.role, "to" => role}
        )

        render_user(conn, updated)

      {:error, _} ->
        refuse(conn, "role_update_failed", "Could not update the role.")
    end
  end

  defp apply_comp(conn, admin, user, true) do
    case Billing.comp_account(user) do
      {:ok, updated} ->
        record_admin(admin, user, "admin.comp.granted", %{
          "email" => user.email,
          "from" => user.comped,
          "to" => updated.comped
        })

        render_user(conn, updated)

      {:error, _} ->
        refuse(conn, "invalid_request", "Could not comp the account.")
    end
  end

  defp apply_comp(conn, admin, user, false) do
    case Billing.revoke_comp(user) do
      {:ok, updated} ->
        record_admin(admin, user, "admin.comp.revoked", %{
          "email" => user.email,
          "from" => user.comped,
          "to" => updated.comped
        })

        render_user(conn, updated)

      # revoke_comp/1 has no other failure mode — it only rejects an account
      # that was not comped in the first place.
      {:error, :not_comped} ->
        refuse(conn, "not_comped", "Account is not comped.")
    end
  end

  defp apply_suspend(conn, admin, user, true) do
    if Accounts.suspended?(user) do
      render_user(conn, user)
    else
      case Accounts.suspend_user(user, actor: "admin") do
        {:ok, updated, reaped} ->
          record_admin(admin, user, "admin.account.suspended", %{
            "email" => user.email,
            "sandboxes_reaped" => reaped
          })

          render_user(conn, updated)

        {:error, _} ->
          refuse(conn, "suspend_failed", "Could not suspend the account.")
      end
    end
  end

  defp apply_suspend(conn, admin, user, false) do
    if Accounts.suspended?(user) do
      case Accounts.unsuspend_user(user, actor: "admin") do
        {:ok, updated} ->
          record_admin(admin, user, "admin.account.unsuspended", %{"email" => user.email})
          render_user(conn, updated)

        {:error, _} ->
          refuse(conn, "unsuspend_failed", "Could not lift the suspension.")
      end
    else
      render_user(conn, user)
    end
  end

  defp apply_delete(conn, admin, user) do
    case Deletion.delete_user(user,
           actor: "admin:#{admin.id}",
           request_ip: client_ip(conn)
         ) do
      {:ok, summary} ->
        record_admin(admin, user, "admin.account.deleted", %{"email" => user.email})

        json(conn, %{
          deleted: true,
          user_id: summary.user_id,
          sprites_destroyed: summary.sprites_destroyed
        })

      {:error, _} ->
        refuse(conn, "delete_failed", "Could not delete the account.")
    end
  end

  ## ── helpers ──────────────────────────────────────────────────────────────

  # Non-bang lookup for every action (#401's lesson from the LiveView): acting
  # on an account deleted since the caller listed it is a 404, not a crash.
  defp with_user(_conn, id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Accounts.get_user(uuid) do
          nil -> {:error, :not_found}
          user -> fun.(user)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp render_user(conn, user) do
    render(conn, :show_user,
      user: user,
      sandbox_counts: Quotas.active_sandbox_counts(),
      admin_events: []
    )
  end

  defp record_admin(admin, user, event_type, metadata) do
    Audit.record_admin(%{
      actor_user_id: admin.id,
      target_user_id: user.id,
      event_type: event_type,
      metadata: metadata
    })
  end

  # The UI hides billing buttons on a billing-disabled instance, but events can
  # still be sent by hand (#399's lesson) — and these all talk to Stripe.
  defp require_billing do
    if Fountain.Credits.enabled?(), do: :ok, else: {:error, :billing_disabled}
  end

  defp refuse(conn, error, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error, message: message})
  end

  defp parse_int(nil, default), do: default
  defp parse_int(n, _default) when is_integer(n), do: n

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_verified("true"), do: true
  defp parse_verified("false"), do: false
  defp parse_verified(true), do: true
  defp parse_verified(false), do: false
  defp parse_verified(_), do: nil

  defp client_ip(conn) do
    case conn.remote_ip do
      nil -> nil
      tuple when is_tuple(tuple) -> tuple |> :inet.ntoa() |> to_string()
      other -> to_string(other)
    end
  end
end
