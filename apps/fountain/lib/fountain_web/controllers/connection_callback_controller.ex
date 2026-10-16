defmodule FountainWeb.ConnectionCallbackController do
  @moduledoc """
  The browser half of connecting a remote MCP server (ADR 0085).

    * `GET /connections/client.json`: Managoat's client ID metadata
      document. Its URL is the client id a provider that supports them is
      given, so it is public and carries nothing secret.
    * `GET /connections/callback`: where the provider sends the browser
      back. Behind the signed-in session: a signed-out browser signs in
      first and comes back here, and `Fountain.Connections.complete/3` only
      finishes a login started by the signed-in user, so nobody can be
      tricked into finishing someone else's consent.
  """

  use FountainWeb, :controller

  alias Fountain.Connections
  alias FountainWeb.Audited

  def client_metadata(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(Connections.client_metadata())
  end

  def callback(conn, params) do
    user = conn.assigns.current_user

    case Connections.complete(user.id, params, Audited.attribution(conn)) do
      {:ok, connection} ->
        conn
        |> put_flash(:info, "Connected #{connection.resource}.")
        |> redirect(external: Fountain.Apps.account_url("connections", connection: "ok"))

      {:error, reason} ->
        conn
        |> put_flash(:error, Connections.error_message(reason))
        |> redirect(external: Fountain.Apps.account_url("connections", connection: "error"))
    end
  end
end
