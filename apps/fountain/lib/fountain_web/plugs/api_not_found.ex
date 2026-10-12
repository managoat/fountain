defmodule FountainWeb.Plugs.ApiNotFound do
  @moduledoc """
  Answers an `/api` path that matched no core route.

  Forwarded at `/api` as the router's last route, inside
  `pipe_through [:accepts_json, :api]`. So an unknown `/api` path gets the same
  treatment as every real one before it gets its 404: content negotiation
  (406), the rate limit, and `TenantAPIAuth` (401) all run first, and only an
  authenticated JSON client learns that the path does not exist. The body is
  the shape the rest of `/api` answers with, rather than Phoenix's
  `NoRouteError`.

  This was the fall-through of the retired extension dispatch (ADR 0043); the
  behaviour of an unmatched `/api` path is unchanged.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found", reason: "not_found"})
    |> halt()
  end
end
