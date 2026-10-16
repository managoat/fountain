defmodule FountainWeb.AdminLive.Shell do
  @moduledoc """
  Shared admin page headings and tables. Section navigation lives in the
  account-style section navigation in FountainWeb.Layouts.
  """

  use Phoenix.Component
  use FountainWeb, :verified_routes

  @doc """
  Header for an admin page: an `<h2>` and an optional one-line description.

  `current` identifies the section in the header markup; the section navigation follows
  the route, including nested detail pages.
  """
  attr :title, :string, required: true
  attr :current, :atom, required: true
  slot :subtitle
  slot :actions

  def admin_header(assigns) do
    ~H"""
    <div class="space-y-4" data-admin-section={@current}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-xl font-semibold">{@title}</h2>
          <p :if={@subtitle != []} class="text-sm text-[var(--color-text-secondary)] mt-1">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  @doc """
  A compact, monospaced table in an admin card, one `:col` per column:

      <.admin_table rows={@hosts} empty="Nothing in this window.">
        <:title>Hosts</:title>
        <:col :let={h} label="Host">{h.host}</:col>
        <:col :let={h} label="Requests" numeric>{h.requests}</:col>
      </.admin_table>

  `numeric` right-aligns the column with tabular figures, `muted` greys it,
  and `class` adds to the cell. A style that depends on the row goes on an
  element inside the cell, since a slot's attributes cannot see `:let`.
  With no rows the card holds `empty` instead of the table.
  """
  attr :rows, :list, required: true
  attr :empty, :string, required: true
  slot :title

  slot :col, required: true do
    attr :label, :string
    attr :numeric, :boolean
    attr :muted, :boolean
    attr :class, :string
  end

  def admin_table(assigns) do
    ~H"""
    <div class="bg-[var(--color-bg-1)] rounded shadow border border-[var(--color-border)] overflow-x-auto">
      <div
        :if={@title != []}
        class="px-4 py-2 text-sm font-medium border-b border-[var(--color-border)]"
      >
        {render_slot(@title)}
      </div>
      <div :if={@rows == []} class="px-4 py-3 text-sm text-[var(--color-text-secondary)]">
        {@empty}
      </div>
      <table :if={@rows != []} class="w-full text-sm font-mono">
        <thead class="text-left text-[var(--color-text-secondary)] border-b border-[var(--color-border)] text-xs">
          <tr>
            <th :for={col <- @col} class={["px-4 py-2", col[:numeric] && "text-right"]}>
              {col[:label]}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-b border-[var(--color-border)] last:border-0">
            <td
              :for={col <- @col}
              class={[
                "px-4 py-1.5 text-xs",
                col[:numeric] && "text-right tabular-nums",
                col[:muted] && "text-[var(--color-text-secondary)]",
                col[:class]
              ]}
            >
              {render_slot(col, row)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
