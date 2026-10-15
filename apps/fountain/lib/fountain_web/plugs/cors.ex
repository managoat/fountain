defmodule FountainWeb.Plugs.Cors do
  @moduledoc """
  CORS for `/api/*`, for a browser client on another origin, such as the
  standalone conversations app.

  Two sources, checked in order. `API_CORS_ORIGINS` is the operator's
  (comma-separated, exact origins such as `https://app.example.com`, or
  `*`). A registered OAuth client's redirect origin is the second, so
  registering an app is enough to call the API from it and no operator has to
  set anything (#1125). With neither, the API stays same-origin plus
  non-browser clients, as it always was.

  The origin is the only thing a preflight carries — it has no
  authentication — which is why "an origin some client registered" is the
  right predicate here: admitting an origin admits nobody who does not
  already hold a bearer key. No cookies are ever allowed across origins
  (`Access-Control-Allow-Credentials` is never sent), so a session cannot be
  ridden from an allowed origin — only an explicitly presented API key works,
  which is the point.

  ## The registry lookup is on the hot path, deliberately

  This plug runs in the endpoint, ahead of the session, the router and both
  of the `:api` pipeline's rate-limit passes. So a request carrying an
  `Origin` the operator did not configure reaches the database before
  anything has authenticated it, once per request, preflights included.

  That is the accepted cost for now, not an oversight. `API_CORS_ORIGINS` is
  checked first and short-circuits; `origin_keys` is GIN-indexed, so the miss
  that the common case is costs one indexed containment; and a cache would
  have to be invalidated on every client write and every deletion, which is
  the part that goes wrong quietly. Measure before adding one — and if the
  measurement says cache, the invalidation is the design, not the cache.

  A preflight (`OPTIONS` with `Access-Control-Request-Method`) from an allowed
  origin is answered here with 204 and never reaches the router, which would
  otherwise 404 it before any header could be set.
  """
  @behaviour Plug

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  # `user-agent` is here for the SDK: it stamps one on every request, and
  # Firefox (unlike Chrome) lets a page set it, which turns the call into a
  # preflight asking for a header this list did not name — "CORS Missing
  # Allow Header" on the first request of a signed-in session.
  @allowed_headers "authorization, content-type, last-event-id, accept, user-agent"
  @exposed_headers "retry-after, x-request-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    with [origin] <- get_req_header(conn, "origin"),
         true <- allowed?(origin) do
      conn = put_cors_headers(conn, origin)

      if preflight?(conn) do
        conn |> send_resp(204, "") |> halt()
      else
        conn
      end
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp origins, do: Application.get_env(:fountain, :api_cors_origins, [])

  defp allowed?(origin) do
    allowed = origins()
    "*" in allowed or origin in allowed or Fountain.OAuth.registered_origin?(origin)
  end

  defp preflight?(%Plug.Conn{method: "OPTIONS"} = conn),
    do: get_req_header(conn, "access-control-request-method") != []

  defp preflight?(_conn), do: false

  # The origin is echoed, never `*`: `*` with a bearer-token client is fine
  # today, but echoing keeps the response cacheable per origin (`Vary`) and
  # means a future credentialed mode does not need a rewrite.
  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
    |> put_resp_header("access-control-expose-headers", @exposed_headers)
    |> put_resp_header("access-control-max-age", "600")
    |> put_resp_header("vary", "origin")
  end
end
