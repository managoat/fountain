defmodule FountainWeb.Plugs.RequireAdminApi do
  @moduledoc """
  The bearer-token analogue of `Live.Hooks.require_admin` (#527).

  Layered on top of `:api` (which authenticates the key and loads the user) and
  `:require_full_scope` (which keeps a sandbox's per-conversation token out).
  This plug is the last of the three, and asks two things: the account has the
  admin role, and the key carries the `admin` scope (#2660).

  The scope is what keeps operator powers out of the admin's ordinary keys. An
  OAuth sign-in mints a full-scope key that lives 30 days, and the CLI's
  `POST /api/auth/token` mints one per login; neither ever carries `admin`
  (`Fountain.Accounts.ApiKey`). Only `Fountain.Accounts.create_admin_api_key/3`
  mints it. The role is still checked, so a demoted admin's admin key stops
  working with the demotion.

  A refusal is 403 rather than 404. There is nothing to hide — the admin API's
  existence is documented — and a 404 would make "you are not an admin"
  indistinguishable from "that endpoint moved", which is a bad half-hour during
  an incident. The two refusals have different codes, `admin_required` and
  `admin_key_required`, so an admin holding the wrong key is told which key to
  mint.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Accounts.ApiKey

  def init(opts), do: opts

  def call(
        %{assigns: %{current_user: %{role: "admin"}, current_api_key: %ApiKey{} = key}} = conn,
        _opts
      ) do
    if ApiKey.admin?(key) do
      conn
    else
      refuse(
        conn,
        "admin_key_required",
        "This endpoint requires an admin key. Mint one on Admin → Admin keys " <>
          "(\"Admin key\"), or with the Fountain.Release.create_admin_key/2 release task."
      )
    end
  end

  def call(conn, _opts) do
    refuse(conn, "admin_required", "This endpoint requires an account with the admin role.")
  end

  defp refuse(conn, error, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: error, message: message})
    |> halt()
  end
end
