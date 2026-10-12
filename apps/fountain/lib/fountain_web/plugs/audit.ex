defmodule FountainWeb.Plugs.Audit do
  @moduledoc """
  Records state-changing API requests to the audit log on the way out.

  Captures:
    * `action`: HTTP verb + the matched *route pattern* (e.g.
      `POST /api/conversations`, `DELETE /api/environments/:environment_id/secrets/:id`).
      The pattern, not the request path: see "Why the pattern and not the path".
    * `resource_type`, `resource_id`: derived from the matched route's
      action + params.
    * `actor`: derived from the credential — `"sprite"` for a per-conversation
      callback token, `"api"` otherwise. Previously hardcoded to `"api"`, which
      made a human, a CI job and an agent running inside a sandbox
      indistinguishable in the trail.
    * `request_ip`: from `conn.remote_ip`.
    * `metadata`: response status code.

  Read methods (GET) are not audited — they're noisy and rarely
  interesting. Failures (4xx/5xx) are still recorded so we can see
  rejected attempts.

  ## Why this stays, now that contexts audit themselves

  #540 moved semantic auditing into the context functions, which means an API
  mutation now writes two rows: `agent.updated` from `Agents.update_agent/3`,
  and `PUT /api/agents/:id` + status from here. That looked like something to
  clean up, and the decision was to keep both — they answer different
  questions:

    * the context event says **what changed** — a semantic action, the fields
      that moved, the resource;
    * this plug says **what was attempted** — verb, path, and the status code,
      including for requests that were refused. A 403 on a route whose context
      never ran leaves no semantic event at all, and a run of them is the
      signal you actually want.

  Scoping this down to "only routes whose context does not audit yet" was the
  alternative, and it was rejected: that list would be a second place to
  remember, one forgotten entry away from a silently unaudited route — the
  exact failure mode #540 existed to remove.

  Recorded as a decision in ADR 0013 §4 — two rows per API mutation is
  intended, and deduplicating them in the UI would lose the refused requests.

  ## Why the pattern and not the path

  This used to record `conn.request_path` verbatim, which put the resource id
  inside the action string: `POST /api/conversations/<uuid>/read` was a
  different action from the same call against a different conversation. Two
  things break when it does.

  The trail loses its only groupable field. "Show me every read of a
  conversation" is a `LIKE` over a column that has one distinct value per
  conversation, and the id is already in `resource_id` where a query can use
  it.

  And anything that groups by `action` — a dashboard, an export — gets one
  bucket per uuid: unbounded cardinality.

  The route pattern is what both want. `Phoenix.Router.route_info/4` gives it
  exactly, from the same match the request already went through. When there is
  no router on the conn or the path does not match a route — neither happens
  on a live request that reached this pipeline, but both happen in a unit test
  that builds a bare conn — uuid-shaped segments are masked to `:id` instead,
  so the fallback is bounded too.
  """

  import Plug.Conn

  alias Fountain.Audit

  @write_methods ~w(POST PUT PATCH DELETE)
  @ignore_paths ~w(/api/openapi.json /api/docs)

  def init(opts), do: opts

  def call(conn, _opts) do
    if should_audit?(conn) do
      register_before_send(conn, &record(&1))
    else
      conn
    end
  end

  defp should_audit?(%{method: m, request_path: p}) do
    m in @write_methods and not Enum.any?(@ignore_paths, &String.starts_with?(p, &1))
  end

  defp record(conn) do
    {resource_type, resource_id} = derive_resource(conn)

    Audit.record(%{
      action: "#{conn.method} #{route_pattern(conn)}",
      resource_type: resource_type,
      resource_id: resource_id,
      actor: actor(conn),
      request_ip: format_ip(conn.remote_ip),
      metadata: %{"status" => conn.status},
      user_id: current_user_id(conn)
    })

    conn
  end

  # The matched route as declared in the router, e.g. "/api/agents/:id". See
  # "Why the pattern and not the path" in the moduledoc for why this is not
  # `conn.request_path`.
  defp route_pattern(conn) do
    with router when not is_nil(router) <- conn.private[:phoenix_router],
         %{route: route} when is_binary(route) <-
           Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
      route
    else
      _ -> mask_ids(conn.request_path)
    end
  end

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  defp mask_ids(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment ->
      if Regex.match?(@uuid, segment), do: ":id", else: segment
    end)
  end

  # A sandbox acting on the tenant's behalf is a materially different claim from
  # the tenant acting directly, and the scopes added for the sandbox
  # privilege-escalation fix make the two distinguishable.
  defp actor(conn) do
    case conn.assigns[:current_api_key] do
      %Fountain.Accounts.ApiKey{scopes: scopes} ->
        if "sprite" in scopes, do: "sprite", else: "api"

      _ ->
        "api"
    end
  end

  defp current_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp derive_resource(conn) do
    params = conn.params || %{}

    cond do
      params["secret_id"] || params["environment_id"] ->
        {"secret", params["secret_id"]}

      params["vault_id"] ->
        {"vault_secret", params["id"]}

      params["conversation_id"] ->
        {"conversation", params["conversation_id"]}

      true ->
        # /api/<resource>[/:id]
        case conn.path_info do
          ["api", res] -> {String.trim_trailing(res, "s"), nil}
          ["api", res, id | _] -> {String.trim_trailing(res, "s"), id}
          _ -> {"unknown", nil}
        end
    end
  end

  defp format_ip(nil), do: nil
  defp format_ip(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(other), do: to_string(other)
end
