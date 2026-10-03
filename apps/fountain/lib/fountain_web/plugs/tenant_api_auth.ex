defmodule FountainWeb.Plugs.TenantAPIAuth do
  @moduledoc """
  API pipeline auth: extracts `Authorization: Bearer <key>`, SHA-256 hashes it,
  looks up the API key, loads the owning user, and sets
  `conn.assigns.current_user`.

  Updates `last_used_at` in an unlinked task under `Fountain.TaskSupervisor`,
  so the stamp never blocks the request and cannot take it down.

  Authentication refusals share a 600/minute per-address budget, separately
  from the pipeline's coarse pre-auth ceiling and authenticated per-key quota.
  A full refusal budget returns 429 without blocking a valid key.

  Returns 401 JSON on failure. The response body includes a machine-readable
  `reason` so clients (especially in-sprite agents holding a rotated
  `$FOUNTAIN_TOKEN`) can tell a revoked key apart from one that never existed:

      {"error": "API key has been revoked", "reason": "api_key_revoked"}
      {"error": "Invalid or missing API key", "reason": "api_key_invalid"}

  An unverified account is refused with 403 and `email_unverified` (#533) —
  the one non-401 here, because the key itself is fine and the account, not
  the credential, is what needs fixing.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  alias Fountain.Accounts
  alias FountainWeb.Plugs.RateLimit

  def init(opts), do: opts

  def call(conn, _opts) do
    with [auth_header] <- get_req_header(conn, "authorization"),
         "Bearer " <> raw_key <- auth_header,
         {:ok, user, api_key} <- Accounts.authenticate_api_key(raw_key) do
      # Unlinked and supervised (#1040). `Task.async` linked this to the conn
      # process and nothing ever awaited it, so a pool blip stamping a column
      # nothing reads on the hot path could kill a request that had already
      # authenticated — and, under the SQL Sandbox, the test that made it.
      #
      # Only when the stamp is due (#2563): a key read as stamped within the
      # last minute needs neither the task nor the query.
      if Accounts.api_key_touch_due?(api_key) do
        Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
          Accounts.touch_api_key(raw_key)
        end)
      end

      # The key's display prefix on every log line of the request. Never the
      # key: the prefix is what the console shows next to the key's name, so
      # a request log can be traced to a key without holding one. Four days
      # of a client polling the API fourteen times a second could be traced
      # only as far as an ingress address without this (2026-09-04).
      Logger.metadata(api_key: api_key.key_prefix)

      conn
      |> assign(:current_user, user)
      # Scope lives on the key, so downstream guards need the record — a sandbox
      # token is otherwise indistinguishable from the tenant's own key.
      |> assign(:current_api_key, api_key)
    else
      {:error, :revoked} ->
        unauthorized(conn, "API key has been revoked", "api_key_revoked")

      {:error, :expired} ->
        unauthorized(conn, "API key has expired", "api_key_expired")

      # Neutral (#287): the key was valid — the holder already knows the
      # account exists; the response still doesn't say why it's unusable.
      {:error, :suspended} ->
        unauthorized(conn, "This account is currently unavailable", "account_unavailable")

      # 403, and named: same status and same `reason` as POST /api/auth/token
      # refusing to mint for this account, so a CLI holding a stale key reads
      # the same answer it would get from asking for a new one. Nothing is
      # leaked by being specific — the holder owns the key.
      {:error, :unverified} ->
        refuse(
          conn,
          :forbidden,
          "Verify your email address before using the API",
          "email_unverified"
        )

      _ ->
        unauthorized(conn, "Invalid or missing API key", "api_key_invalid")
    end
  end

  defp unauthorized(conn, message, reason), do: refuse(conn, :unauthorized, message, reason)

  defp refuse(conn, status, message, reason) do
    conn = RateLimit.call(conn, RateLimit.init(bucket: "api-auth-failure", max: 600))

    if conn.halted do
      conn
    else
      conn
      |> put_status(status)
      |> json(%{error: message, reason: reason})
      |> halt()
    end
  end
end
