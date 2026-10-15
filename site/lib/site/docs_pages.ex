defmodule Site.DocsPages do
  @moduledoc """
  The manual's page shell: the sidebar (nav and search), the article, and the
  scripts that add a copy button to every code block and search the index.

  Ported from the Fountain server's `FountainWeb.DocsHTML` on 2026-10-15,
  when the manual became part of this static build (decisions/0081). The
  one change in behaviour is the search index: the server inlined it into
  every page, and here it is one file, `/docs/search-index.json`, fetched the
  first time a reader uses the search box.
  """
  use Phoenix.Component

  embed_templates("docs_pages/*")

  @doc "Served path for a slug (`\"\"` is the manual's home)."
  def docs_path(slug), do: Site.Manual.path_for_slug(slug)

  attr(:nav, :list, required: true)
  attr(:slug, :string, required: true)

  @doc """
  The nav list, shared by the sidebar and the small-screen menu: the home
  page, then one collapsible group per category (`Site.Manual.nav/0`).

  A category is a `<details>`, so it needs no script. The one holding the
  page being read starts open and the rest start closed, so the sidebar
  reads as four headings plus where you are; on a page outside every
  category (the home page) all of them start open.
  """
  def nav_links(assigns) do
    in_a_category? =
      Enum.any?(assigns.nav, fn
        {_category, children} = entry when is_list(children) -> contains?(entry, assigns.slug)
        _page -> false
      end)

    assigns = assign(assigns, :open_all, not in_a_category?)

    ~H"""
    <%= for {title, item} = entry <- @nav do %>
      <%= if is_list(item) do %>
        <details
          class="group mt-3 first:mt-0"
          data-role="docs-nav-category"
          open={@open_all or contains?(entry, @slug)}
        >
          <summary class="flex cursor-pointer list-none items-center gap-1.5 rounded px-2 py-1.5 text-xs font-semibold uppercase tracking-wider text-[var(--color-text-primary)] hover:bg-[var(--color-bg-2)] [&::-webkit-details-marker]:hidden">
            <svg
              class="h-3 w-3 shrink-0 text-[var(--color-text-muted)] transition-transform group-open:rotate-90"
              viewBox="0 0 12 12"
              aria-hidden="true"
            >
              <path d="M4.5 2.5 8 6l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.5" />
            </svg>
            {title}
          </summary>
          <div class="mt-1 space-y-1">
            <%= for {child_title, child} <- item do %>
              <%= if is_list(child) do %>
                <div class="pt-2 pb-1">
                  <div class="text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium mb-1 px-2">
                    {child_title}
                  </div>
                  <div class="ml-3 pl-2 border-l border-[var(--color-border)] space-y-1">
                    <%= for {page_title, page_slug} <- child do %>
                      <.nav_link title={page_title} slug={page_slug} current={@slug} />
                    <% end %>
                  </div>
                </div>
              <% else %>
                <.nav_link title={child_title} slug={child} current={@slug} />
              <% end %>
            <% end %>
          </div>
        </details>
      <% else %>
        <.nav_link title={title} slug={item} current={@slug} />
      <% end %>
    <% end %>
    """
  end

  # Whether a nav entry is, or holds at any depth, the page at `slug`.
  defp contains?({_header, children}, slug) when is_list(children),
    do: Enum.any?(children, &contains?(&1, slug))

  defp contains?({_title, page_slug}, slug), do: page_slug == slug

  attr(:title, :string, required: true)
  attr(:slug, :string, required: true)
  attr(:current, :string, required: true)

  defp nav_link(assigns) do
    ~H"""
    <a
      href={docs_path(@slug)}
      aria-current={@slug == @current && "page"}
      class={[
        "block rounded px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]",
        @slug == @current && "bg-[var(--color-bg-2)] font-medium text-[var(--color-text-primary)]",
        @slug != @current && "text-[var(--color-text-secondary)]"
      ]}
    >
      {@title}
    </a>
    """
  end
end
