defmodule FountainWeb.AdminLive.Activity do
  @moduledoc """
  `/admin/activity` — the privilege trail: which operator did what to which
  account, newest first.

  The admin overview used to show the newest 25 of these at the bottom of a
  long page, with no way to reach the 26th. The trail is the record an
  operator is answerable for, so it is paginated here rather than truncated.

  Distinct from `/audit`, which is a tenant's own trail over their own
  resources. This one is the trail of actions taken *against* an account by
  somebody who does not own it.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Audit

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin · Activity")}
  end

  # The page lives in the URL so a link to "what happened last week" is a link
  # somebody can paste into a support thread.
  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])

    %{events: events, total: total} =
      Audit._unsafe_page_admin_events(page: page, per_page: @per_page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:events, events)
     |> assign(:total, total)}
  end

  defp parse_page(raw) do
    case is_binary(raw) && Integer.parse(raw) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp page_count(total), do: max(div(total + @per_page - 1, @per_page), 1)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Activity" current={:activity}>
        <:subtitle>
          Role grants, quota changes, comps, suspensions and deletions — who did what to whom.
        </:subtitle>
      </.admin_header>

      <section class="space-y-3">
        <div :if={@events == []} class="text-sm text-[var(--color-text-secondary)]">Nothing yet.</div>

        <table
          :if={@events != []}
          class="w-full text-sm bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)]"
        >
          <thead class="text-left text-[var(--color-text-secondary)] border-b border-[var(--color-border)]">
            <tr>
              <th class="px-4 py-2">When</th>
              <th class="px-4 py-2">Action</th>
              <th class="px-4 py-2">Target</th>
              <th class="px-4 py-2">Detail</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @events} class="border-b border-[var(--color-border)] last:border-0">
              <td class="px-4 py-2 text-xs text-[var(--color-text-secondary)] whitespace-nowrap">
                {format_ts(e.inserted_at)}
              </td>
              <td class="px-4 py-2 font-mono text-xs">{e.event_type}</td>
              <td class="px-4 py-2 font-mono text-xs">
                <.link
                  :if={e.target_user_id}
                  navigate={~p"/admin/users/#{e.target_user_id}"}
                  class="hover:underline"
                >
                  {e.metadata["email"]}
                </.link>
                <span :if={is_nil(e.target_user_id)}>
                  {e.metadata["email"] || e.metadata["provider"]}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-[var(--color-text-secondary)]">
                <span :if={e.metadata["from"] != nil}>
                  {e.metadata["from"]} &rarr; {e.metadata["to"]}
                </span>
              </td>
            </tr>
          </tbody>
        </table>

        <div
          :if={page_count(@total) > 1 or @page > 1}
          class="flex items-center justify-between text-xs text-[var(--color-text-secondary)]"
        >
          <span>Page {@page} of {page_count(@total)} · {@total} events</span>
          <div class="space-x-3">
            <.link :if={@page > 1} patch={~p"/admin/activity?page=#{@page - 1}"} class="underline">
              ← prev
            </.link>
            <.link
              :if={@page < page_count(@total)}
              patch={~p"/admin/activity?page=#{@page + 1}"}
              class="underline"
            >
              next →
            </.link>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
