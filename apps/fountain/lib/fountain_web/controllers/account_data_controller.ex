defmodule FountainWeb.AccountDataController do
  @moduledoc """
  Account deletion over the API (#523).

  Deletion is gated on `full` scope (a sandbox's token must not be able to
  destroy the tenant) *and* on a typed confirmation, the same double check the
  UI applies.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts.Deletion
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Account"])

  operation(:delete_account,
    summary: "Delete the account and everything in it",
    description:
      "Irreversible. Destroys sandboxes, deletes every " <>
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
