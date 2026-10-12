defmodule FountainWeb.AuditController do
  @moduledoc """
  The tenant's own audit trail over the API (#526).

  The trail was readable at `/audit` in a browser only. Anything that wanted
  to ship its own audit events somewhere — a SIEM, a compliance archive, a
  weekly digest — had to scrape a LiveView.

  Tenant-scoped by construction: `Audit.list_for_user/2` filters on `user_id`,
  and cross-tenant listing belongs to the admin API, not here.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Audit
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  @default_limit 100
  @max_limit 500

  tags(["Audit"])

  operation(:index,
    summary: "List the account's audit events",
    description:
      "Newest first, cursor-paginated: pass the previous page's " <>
        "`meta.next_cursor` as `before`. Only this tenant's events; system and " <>
        "cross-tenant rows are not visible here.",
    parameters: [
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size, 1..#{@max_limit}. Defaults to #{@default_limit}."
      ],
      before: [
        in: :query,
        type: :integer,
        required: false,
        description: "Return events older than this event id."
      ],
      action_prefix: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Match actions starting with this string, e.g. `vault.` for every " <>
            "vault event. Treated as a literal — LIKE metacharacters do not apply."
      ],
      resource_type: [
        in: :query,
        type: :string,
        required: false,
        description: "Exact match, e.g. `secret`, `vault_secret`, `conversation`."
      ],
      since: [
        in: :query,
        type: :string,
        required: false,
        description: "ISO 8601 timestamp; events at or after it."
      ],
      until: [
        in: :query,
        type: :string,
        required: false,
        description: "ISO 8601 timestamp; events at or before it."
      ]
    ],
    responses: [
      ok: {"Audit events", "application/json", Schemas.AuditEventListResponse},
      bad_request: {"Malformed since/until", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_limit(params["limit"])

    with {:ok, since} <- parse_time(params["since"], "since"),
         {:ok, until} <- parse_time(params["until"], "until") do
      # One extra row answers has_more without a second count query.
      events =
        Audit.list_for_user(user.id,
          limit: limit + 1,
          before_id: parse_before(params["before"]),
          action_prefix: params["action_prefix"],
          resource_type: params["resource_type"],
          since: since,
          until: until
        )

      {page, has_more?} =
        case Enum.split(events, limit) do
          {page, []} -> {page, false}
          {page, _} -> {page, true}
        end

      render(conn, :index, events: page, has_more: has_more?, limit: limit)
    end
  end

  defp parse_limit(nil), do: @default_limit
  defp parse_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> parse_limit(n)
      :error -> @default_limit
    end
  end

  defp parse_before(nil), do: nil
  defp parse_before(n) when is_integer(n), do: n

  defp parse_before(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_time(nil, _field), do: {:ok, nil}
  defp parse_time("", _field), do: {:ok, nil}

  defp parse_time(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      # A silently-ignored bad timestamp would return the unfiltered trail and
      # look like "nothing matched my window" — worse than a refusal.
      {:error, _} -> {:error, "#{field} must be an ISO 8601 timestamp"}
    end
  end
end
