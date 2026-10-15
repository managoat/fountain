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

  @doc "The nav list, shared by the sidebar and the small-screen menu."
  def nav_links(assigns) do
    ~H"""
    <%= for {title, item} <- @nav do %>
      <%= if is_list(item) do %>
        <div class="mt-4 mb-2">
          <div class="text-[10px] uppercase tracking-wider text-[var(--color-text-muted)] font-medium mb-1 px-2">
            {title}
          </div>
          <div class="ml-3 pl-2 border-l border-[var(--color-border)] space-y-1">
            <%= for {child_title, child_slug} <- item do %>
              <.nav_link title={child_title} slug={child_slug} current={@slug} />
            <% end %>
          </div>
        </div>
      <% else %>
        <.nav_link title={title} slug={item} current={@slug} />
      <% end %>
    <% end %>
    """
  end

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
