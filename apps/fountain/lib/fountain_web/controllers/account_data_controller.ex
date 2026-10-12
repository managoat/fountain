defmodule FountainWeb.AccountDataController do
  @moduledoc """
  Account data export and account deletion over the API (#523).

  Both were browser-only: export lived in `AccountLive` with PubSub progress
  and a session-scoped download, deletion behind a typed-email confirmation.
  These are the closest things Fountain has to GDPR flows, and a product whose
  pitch is "drive everything programmatically" could drive neither.

  The API has no PubSub, so export progress is polled rather than pushed —
  `POST` returns the pending row, `GET` reports where it got to.

  Deletion is gated on `full` scope (a sandbox's token must not be able to
  destroy the tenant) *and* on a typed confirmation, the same double check the
  UI applies.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts.Deletion
  alias Fountain.Exports
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Account"])

  operation(:create_export,
    summary: "Request an account data export",
    description:
      "Builds asynchronously. At most one export exists per account and one " <>
        "request per hour; a request inside that window is refused with 429 and " <>
        "a `Retry-After` header. Poll `GET /api/account/exports` for status.",
    responses: [
      accepted: {"Pending export", "application/json", Schemas.ExportResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      too_many_requests: {"Rate limited", "application/json", Schemas.Error}
    ]
  )

  def create_export(conn, _params) do
    user = conn.assigns.current_user

    case Exports.request_export(user, actor: "api", request_ip: client_ip(conn)) do
      {:ok, export} ->
        conn
        |> put_status(:accepted)
        |> render(:show_export, export: export)

      {:error, {:rate_limited, retry_after}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> json(%{
          error: "rate_limited",
          message: "One export per hour. Try again in #{retry_after}s.",
          retry_after: retry_after
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  operation(:index_exports,
    summary: "List account data exports",
    description:
      "At most one export exists per account, so this is a zero- or one-element " <>
        "list — the shape matches the rest of the API rather than 404-ing when " <>
        "no export has been requested.",
    responses: [
      ok: {"Exports", "application/json", Schemas.ExportListResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error}
    ]
  )

  def index_exports(conn, _params) do
    case Exports.latest_export(conn.assigns.current_user.id) do
      nil -> render(conn, :index_exports, exports: [])
      export -> render(conn, :index_exports, exports: [export])
    end
  end

  operation(:show_export,
    summary: "Get an export's status",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Export", "application/json", Schemas.ExportResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show_export(conn, %{"id" => id}) do
    case Exports.get_export(id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      export -> render(conn, :show_export, export: export)
    end
  end

  operation(:download_export,
    summary: "Download a completed export",
    description:
      "The gzipped JSON payload, served with `content-encoding: gzip`. 404 " <>
        "covers every not-downloadable case identically — wrong tenant, missing " <>
        "id, still pending, failed, expired — so nothing about other tenants' " <>
        "artifacts is inferable.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Export payload", "application/json", %OpenApiSpex.Schema{type: :string}},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def download_export(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Exports.get_downloadable_export(id, user.id) do
      {:ok, export} ->
        # Same audit event the session route records — the trail should not
        # care which surface pulled the bytes.
        Audited.from_conn(conn, "account.export_downloaded", "export",
          resource_id: export.id,
          metadata: %{"byte_size" => export.byte_size}
        )

        filename = "fountain-export-#{Date.to_iso8601(Date.utc_today())}.json"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-encoding", "gzip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, export.payload)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  operation(:delete_account,
    summary: "Delete the account and everything in it",
    description:
      "Irreversible. Cancels billing, destroys sandboxes, deletes every " <>
        "resource and the tenant encryption key. Requires `{\"confirm\": " <>
        "\"<your account email>\"}` in the body — the API equivalent of the " <>
        "UI's typed-email gate — and a `full`-scoped key.",
    request_body: {"Confirmation", "application/json", Schemas.AccountDeleteRequest},
    responses: [
      ok: {"Deleted", "application/json", Schemas.AccountDeletedResponse},
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      unprocessable_entity: {"Confirmation mismatch", "application/json", Schemas.Error}
    ]
  )

  def delete_account(conn, params) do
    user = conn.assigns.current_user

    if confirmed?(params["confirm"], user.email) do
      perform_deletion(conn, user)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        error: "confirmation_required",
        message: "Send {\"confirm\": \"<your account email>\"} to delete this account."
      })
    end
  end

  defp perform_deletion(conn, user) do
    case Deletion.delete_user(user, actor: "api", request_ip: client_ip(conn)) do
      {:ok, summary} ->
        json(conn, %{
          deleted: true,
          user_id: summary.user_id,
          sprites_destroyed: summary.sprites_destroyed
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Exact match, like the UI's typed-email gate. Compared in constant time out
  # of habit rather than need — this is a confirmation, not a secret.
  defp confirmed?(confirm, email) when is_binary(confirm) and is_binary(email),
    do: Plug.Crypto.secure_compare(confirm, email)

  defp confirmed?(_, _), do: false

  defp client_ip(conn) do
    case conn.remote_ip do
      nil -> nil
      tuple when is_tuple(tuple) -> tuple |> :inet.ntoa() |> to_string()
      other -> to_string(other)
    end
  end
end
