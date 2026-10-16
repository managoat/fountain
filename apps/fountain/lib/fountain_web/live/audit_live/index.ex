defmodule FountainWeb.AuditLive.Index do
  @moduledoc """
  The audit trail in a browser.

  #526 gave `GET /api/audit` filters — action prefix, resource type, time
  bounds — and this page had none, so the API was strictly better than the UI
  at the one thing the UI exists for: "show me every `vault.` event since
  Tuesday" was a curl away and impossible in a browser. #572 gives the page
  the same filters, backed by the same `Audit` query.

  Filter state lives in the URL, so a filtered view is a link you can send
  someone and it survives the 5s refresh and a reload.
  """
  use FountainWeb, :live_view

  alias Fountain.Audit

  @limit 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 5_000)

    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     |> assign(:is_admin, user.role == "admin")
     |> assign(:limit, @limit)
     |> assign(:resource_types, load_resource_types(user))}
  end

  # Filters live in the URL rather than in socket state: the 5s refresh, a
  # reload and a shared link all land on the same view.
  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:events, load_events(socket.assigns.current_user, filters))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: audit_path(parse_filters(params)))}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 5_000)

    {:noreply,
     assign(socket, :events, load_events(socket.assigns.current_user, socket.assigns.filters))}
  end

  # Ownership: the function head is the admin gate — same predicate as
  # require_admin; every other user hits the tenant-scoped clause below.
  defp load_events(%{role: "admin"}, filters),
    do: Audit._unsafe_list_events(query_opts(filters))

  defp load_events(%{id: id}, filters), do: Audit.list_for_user(id, query_opts(filters))

  # Ownership: as above.
  defp load_resource_types(%{role: "admin"}), do: Audit._unsafe_list_resource_types()
  defp load_resource_types(%{id: id}), do: Audit.list_resource_types_for_user(id)

  defp query_opts(f) do
    [
      limit: @limit,
      action_prefix: f.action_prefix,
      resource_type: f.resource_type,
      since: f.since,
      until: f.until
    ]
  end

  ## Filter parsing

  defp parse_filters(params) do
    %{
      action_prefix: params["action"] |> to_string() |> String.trim(),
      resource_type: params["resource"] |> to_string() |> String.trim(),
      # Kept as the raw form value as well as the parsed DateTime: the input
      # has to render what the user typed, and an unparseable value must not
      # silently vanish from the box while the results ignore it.
      since_raw: params["since"] |> to_string() |> String.trim(),
      until_raw: params["until"] |> to_string() |> String.trim(),
      since: parse_time(params["since"]),
      until: parse_time(params["until"])
    }
  end

  # `datetime-local` posts "2026-08-05T14:30", and some browsers append
  # seconds. Read as UTC, which is what the table renders. An unparseable
  # value filters nothing rather than erroring — the input keeps showing it,
  # so a half-typed date is visibly half-typed and not silently applied.
  defp parse_time(value) when is_binary(value) do
    trimmed = String.trim(value)

    with {:error, _} <- NaiveDateTime.from_iso8601(trimmed),
         {:error, _} <- NaiveDateTime.from_iso8601(trimmed <> ":00") do
      nil
    else
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
    end
  end

  defp parse_time(_), do: nil

  defp audit_path(f) do
    params =
      [
        action: blank_to_nil(f.action_prefix),
        resource: blank_to_nil(f.resource_type),
        since: blank_to_nil(f.since_raw),
        until: blank_to_nil(f.until_raw)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/audit?#{params}"
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp any_filter?(f) do
    f.action_prefix != "" or f.resource_type != "" or f.since_raw != "" or f.until_raw != ""
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <a href={~p"/dashboard"} class="inline-block text-sm text-[var(--color-brand)] hover:underline">← Dashboard</a>
      <h1 class="text-2xl font-semibold">Audit log</h1>
      <p class="text-sm text-[var(--color-text-secondary)]">
        Last {@limit} state-changing API calls. Updates every 5s.
        <span :if={@is_admin}>Admin view: every tenant.</span>
      </p>

      <form phx-change="filter" id="audit-filters" class="flex flex-wrap items-end gap-2">
        <label class="flex flex-col gap-1 text-xs text-[var(--color-text-secondary)]">
          action starts with
          <input
            type="text"
            name="action"
            value={@filters.action_prefix}
            placeholder="vault."
            phx-debounce="300"
            autocomplete="off"
            class="w-40 rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] px-2 py-1 font-mono text-xs"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-[var(--color-text-secondary)]">
          resource
          <select
            name="resource"
            class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] px-1 py-1 text-xs"
          >
            <option value="">any</option>
            <option
              :for={type <- @resource_types}
              value={type}
              selected={@filters.resource_type == type}
            >
              {type}
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-xs text-[var(--color-text-secondary)]">
          since (UTC)
          <input
            type="datetime-local"
            name="since"
            value={@filters.since_raw}
            class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] px-2 py-1 text-xs"
          />
        </label>
        <label class="flex flex-col gap-1 text-xs text-[var(--color-text-secondary)]">
          until (UTC)
          <input
            type="datetime-local"
            name="until"
            value={@filters.until_raw}
            class="rounded border border-[var(--color-border)] bg-[var(--color-bg-1)] px-2 py-1 text-xs"
          />
        </label>
        <.link
          :if={any_filter?(@filters)}
          patch={~p"/audit"}
          class="px-2 py-1 text-xs text-[var(--color-text-secondary)] underline hover:text-[var(--color-text-primary)]"
        >
          clear filters
        </.link>
      </form>

      <div
        :if={@events == [] and any_filter?(@filters)}
        class="rounded border border-dashed border-[var(--color-border-strong)] p-8 text-center text-[var(--color-text-secondary)]"
      >
        No events match these filters.
      </div>

      <div
        :if={@events == [] and not any_filter?(@filters)}
        class="rounded border border-dashed border-[var(--color-border-strong)] p-8 text-center text-[var(--color-text-secondary)]"
      >
        No events yet.
      </div>

      <div
        :if={@events != []}
        class="overflow-x-auto"
        role="region"
        aria-label="Audit events"
        tabindex="0"
      >
        <table class="w-full text-sm bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] font-mono">
          <thead class="text-left text-[var(--color-text-secondary)] border-b border-[var(--color-border)]">
            <tr>
              <th class="px-3 py-2">when</th>
              <th class="px-3 py-2">actor</th>
              <th class="px-3 py-2">action</th>
              <th class="px-3 py-2">resource</th>
              <th class="px-3 py-2">status</th>
              <th class="px-3 py-2">ip</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @events} class="border-b border-[var(--color-border)] last:border-0">
              <td class="px-3 py-1.5 text-[var(--color-text-secondary)] text-xs">
                {format_ts(e.inserted_at)}
              </td>
              <td class="px-3 py-1.5">{e.actor || "—"}</td>
              <td class="px-3 py-1.5">{e.action}</td>
              <td class="px-3 py-1.5">
                {e.resource_type}
                <span :if={e.resource_id} class="text-[var(--color-text-muted)]">
                  /{String.slice(e.resource_id, 0, 8)}
                </span>
              </td>
              <td class="px-3 py-1.5">{e.metadata["status"] || "—"}</td>
              <td class="px-3 py-1.5 text-[var(--color-text-secondary)]">{e.request_ip || "—"}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={length(@events) == @limit} class="text-xs text-[var(--color-text-secondary)]">
        Showing the newest {@limit} matches — narrow the filters to see further back,
        or page the whole trail with <code>GET /api/audit</code>.
      </p>
    </div>
    """
  end

  defp format_ts(nil), do: ""
  defp format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
