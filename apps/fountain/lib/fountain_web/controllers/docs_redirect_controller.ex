defmodule FountainWeb.DocsRedirectController do
  @moduledoc """
  Where the manual went (decisions/0081).

  The server used to serve the manual at `/docs`, and its llms.txt files and
  skill beside it, compiled in from `docs/`. The manual is a static build in
  `site/` now, published at `DOCS_URL` (`https://managoat.com` by default), so
  every one of those paths is a permanent redirect to the same path there.
  In-app links keep saying `/docs/...`, and a bookmark, an old email or an
  agent's saved instructions still land on the page they meant.

  On managoat.com Traefik sends these paths to the site and they never reach
  this controller. If `DOCS_URL` names the host the request came in on, a
  redirect would loop, so the answer is a 404 that says why.
  """
  use FountainWeb, :controller

  def show(conn, _params) do
    base = Fountain.DocsUrl.base()

    if URI.parse(base).host == conn.host do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(
        404,
        "This server does not serve the manual, and DOCS_URL (#{base}) points at it.\n"
      )
    else
      conn
      |> put_status(:moved_permanently)
      |> redirect(external: Fountain.DocsUrl.url(conn.request_path, conn.query_string))
    end
  end
end
