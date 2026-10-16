defmodule FountainWeb.Layouts do
  @moduledoc """
  Shared console header and footer, with account-style section navigation
  for administration. Conversations is an external OAuth app.
  """
  use FountainWeb, :html

  embed_templates "layouts/*"

  def app(assigns) do
    assigns =
      assign(assigns,
        conversations_app: Fountain.Apps.conversations(),
        account_app: Fountain.Apps.account_url()
      )

    ~H"""
    <div class="min-h-screen bg-[var(--color-bg-0)] text-[var(--color-text-primary)]">
      <.flash_group flash={@flash} />
      <header id="user-header" class="border-b border-[var(--color-border)] bg-[var(--color-bg-1)]">
        <div class="max-w-6xl mx-auto px-4 sm:px-6 py-4 flex flex-wrap items-center justify-between gap-4">
          <a href={~p"/dashboard"} class="flex items-center gap-2 text-sm font-semibold">
            <img src="/images/app-icon.png" alt="" class="size-7 rounded-md" /> Managoat
          </a>
          <nav aria-label="Primary navigation" class="flex flex-wrap items-center gap-1 text-sm">
            <.nav_link href={~p"/dashboard"} label="Dashboard" current={@current_path} />
            <.nav_link href={~p"/docs"} label="Docs" current={@current_path} />
            <.app_link :if={@conversations_app} href={@conversations_app} label="Conversations" />
            <.nav_link
              href={@account_app}
              label="Account"
              current={@current_path}
            />
            <.nav_link
              :if={assigns[:current_user] && @current_user.role == "admin"}
              href={~p"/admin"}
              label="Admin"
              current={@current_path}
            />
            <.theme_toggle />
          </nav>
        </div>
      </header>
      <main id="user-content" class="max-w-6xl mx-auto px-4 sm:px-6 py-8">
        <%= if String.starts_with?(@current_path || "", "/admin") do %>
          <.admin_sections current={@current_path}>{@inner_content}</.admin_sections>
        <% else %>
          {@inner_content}
        <% end %>
      </main>
      <footer class="max-w-6xl mx-auto px-4 sm:px-6 py-6 border-t border-[var(--color-border)] flex flex-wrap items-center justify-between gap-3 text-xs text-[var(--color-text-secondary)]">
        <span :if={assigns[:current_user]} class="break-all">{@current_user.email}</span>
        <div class="flex items-center gap-4">
          <a href={~p"/auth/logout"} class="hover:underline">Sign out</a>
          <span class="font-mono text-[var(--color-text-muted)]">{build_version()}</span>
        </div>
      </footer>
    </div>
    """
  end

  defp theme_toggle(assigns) do
    ~H"""
    <button
      id="theme-toggle"
      phx-hook="ThemeToggle"
      type="button"
      aria-label="Toggle dark mode"
      class="shrink-0 rounded-md p-1.5 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-focus-ring)]"
    >
      <svg
        id="theme-icon-moon"
        class="size-4"
        viewBox="0 0 20 20"
        fill="currentColor"
        aria-hidden="true"
      >
        <path d="M17.293 13.293A8 8 0 0 1 6.707 2.707a8.001 8.001 0 1 0 10.586 10.586z" />
      </svg>
      <svg
        id="theme-icon-sun"
        class="size-4 hidden"
        viewBox="0 0 20 20"
        fill="currentColor"
        aria-hidden="true"
      >
        <path
          fill-rule="evenodd"
          d="M10 2a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0V3a1 1 0 0 1 1-1Zm4 8a4 4 0 1 1-8 0 4 4 0 0 1 8 0Zm-.464 4.95.707.707a1 1 0 0 0 1.414-1.414l-.707-.707a1 1 0 0 0-1.414 1.414Zm2.12-10.607a1 1 0 0 1 0 1.414l-.706.707a1 1 0 1 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 0ZM17 11a1 1 0 1 0 0-2h-1a1 1 0 1 1 0 2h1Zm-7 4a1 1 0 0 1 1 1v1a1 1 0 1 1-2 0v-1a1 1 0 0 1 1-1ZM5.05 6.464A1 1 0 1 0 6.465 5.05l-.708-.707a1 1 0 0 0-1.414 1.414l.707.707Zm1.414 8.486-.707.707a1 1 0 0 1-1.414-1.414l.707-.707a1 1 0 0 1 1.414 1.414ZM4 11a1 1 0 1 0 0-2H3a1 1 0 0 0 0 2h1Z"
          clip-rule="evenodd"
        />
      </svg>
    </button>
    """
  end

  attr :current, :string, required: true
  slot :inner_block, required: true

  defp admin_sections(assigns) do
    sections = [
      {"/admin", "Overview", "Administration"},
      {"/admin/users", "Users", "Administration"},
      {"/admin/sandboxes", "Sandboxes", "Administration"},
      {"/admin/broker", "Broker", "Administration"},
      {"/admin/keys", "Admin keys", "Administration"},
      {"/audit", "Audit log", "Activity"}
    ]

    selected =
      Enum.find_value(sections, "/admin", fn {path, _, _} ->
        if assigns.current == path or
             (path != "/admin" and String.starts_with?(assigns.current, path <> "/")) do
          path
        end
      end)

    assigns = assign(assigns, sections: sections, selected: selected)

    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-semibold">Admin</h1>
        <p class="mt-1 text-sm text-[var(--color-text-secondary)]">
          Manage this server and its users.
        </p>
      </div>
      <div id="admin-settings" class="grid gap-8 md:grid-cols-[190px_minmax(0,1fr)]">
        <nav id="admin-sections" aria-label="Admin sections" class="hidden md:block space-y-6">
          <div :for={group <- ["Administration", "Activity"]}>
            <p class="mb-2 px-3 text-xs font-medium uppercase tracking-wide text-[var(--color-text-muted)]">
              {group}
            </p>
            <a
              :for={{path, title, item_group} <- @sections}
              :if={item_group == group}
              href={path}
              aria-current={if @selected == path, do: "page"}
              class={[
                "block rounded-md px-3 py-2 text-sm",
                if(@selected == path,
                  do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-brand)]",
                  else: "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
                )
              ]}
            >{title}</a>
          </div>
        </nav>
        <div class="md:hidden">
          <label for="admin-section-picker" class="block mb-2 text-sm">Admin section</label>
          <select
            id="admin-section-picker"
            phx-hook="SectionNavigation"
            class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-1)] p-2"
          >
            <option :for={{path, title, _} <- @sections} value={path} selected={@selected == path}>
              {title}
            </option>
          </select>
        </div>
        <div id="admin-content" class="min-w-0">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  # Deployment marker shown in the shared footer. Combines the
  # umbrella app version with the short git SHA this deployment is running.
  # `MANAGOAT_BUILD_SHA` is baked into every image as a docker build-arg
  # (release.yml and build.yml both pass BUILD_SHA). It names the commit the
  # image was built from — which, when a build is skipped for an identical
  # tree, is older than the commit deployed. Local dev falls back to "dev".
  defp build_version do
    vsn = :fountain |> Application.spec(:vsn) |> to_string()
    sha = (Application.get_env(:fountain, :build_sha) || "dev") |> String.slice(0, 7)
    "v#{vsn} · #{sha}"
  end

  attr :href, :string, required: true
  attr :label, :string, required: true

  # An app on its own origin: a plain <a>, and said so, because it leaves
  # Fountain's session behind and signs in with its own token.
  defp app_link(assigns) do
    ~H"""
    <a
      href={@href}
      class="flex items-center gap-1.5 rounded-md px-3 py-1 text-sm text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)] transition-colors"
    >
      {@label}
      <svg
        class="size-3 shrink-0 opacity-60"
        viewBox="0 0 20 20"
        fill="currentColor"
        aria-hidden="true"
      >
        <path d="M11 3a1 1 0 1 0 0 2h2.586l-6.293 6.293a1 1 0 1 0 1.414 1.414L15 6.414V9a1 1 0 1 0 2 0V4a1 1 0 0 0-1-1h-5Z" />
        <path d="M5 5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-3a1 1 0 1 0-2 0v3H5V7h3a1 1 0 0 0 0-2H5Z" />
      </svg>
    </a>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :current, :string, default: ""
  # Highlight only on an exact path match — for links like /account whose
  # href is a prefix of sibling pages (/account/inference-credentials, /account/bindings).
  attr :exact, :boolean, default: false

  defp nav_link(assigns) do
    active =
      if assigns.exact do
        assigns.current == assigns.href
      else
        (String.starts_with?(assigns.current || "", assigns.href) and assigns.href != "/") or
          assigns.current == assigns.href
      end

    assigns = assign(assigns, active: active, link_attrs: [href: assigns.href])

    ~H"""
    <.link
      {@link_attrs}
      aria-current={if @active, do: "page"}
      class={[
        "block rounded-md px-3 py-1 text-sm transition-colors",
        if(@active,
          do: "bg-[var(--color-bg-2)] font-medium text-[var(--color-text-primary)]",
          else:
            "text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)] hover:text-[var(--color-text-primary)]"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end
end
