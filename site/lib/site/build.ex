defmodule Site.Build do
  @moduledoc """
  Renders every page to `dist/` and copies the assets beside them.

  A page is a path, the template that renders it, and the title and
  description its card carries. Output file names follow the served path with
  `.html` appended (`/built-with` → `built-with.html`, `/docs/concepts/vault`
  → `docs/concepts/vault.html`) and `/` is `index.html`, which is the shape
  `nginx.conf`'s `try_files` serves without a redirect.

  Two site pages since 2026-10-15. The launch page, the case study, the code
  review bot, self-host, the questions page and integrations were cut; what
  was worth keeping from the last three moved into the manual
  (`docs/self-hosting.md`, `docs/reference/security.md`,
  `docs/integrations/editors.md`).

  And the manual, since the same day (decisions/0081): one page per slug of
  `docs/nav.yml` at `/docs/<slug>` (`Site.Manual`, `Site.Markdown`,
  `Site.DocsPages`), its search index at `/docs/search-index.json`, and the
  llms.txt files (`Site.Llms`).
  """

  @site_title "Claude Code, Codex and Gemini CLI behind one API"

  @doc "The description a page uses when it sets none: the pitch."
  def default_description do
    "#{Site.Brand.name()} is a conversational API to a computer, built on the " <>
      "open-source #{Site.Brand.engine()} server. The machine arrives with your " <>
      "repositories and credentials and keeps its work between prompts."
  end

  @doc "Every site page (the manual's are `docs_pages/0`)."
  def pages do
    brand = Site.Brand.name()

    [
      %{
        path: "/",
        template: :home,
        title: "#{@site_title} · #{brand}",
        description: default_description()
      },
      %{
        path: "/built-with",
        template: :built_with,
        title: "Built with #{brand} · #{brand}",
        description:
          "#{length(Site.Pages.built_apps_flat())} open-source " <>
            "applications built on the #{brand} API. Explore chat, " <>
            "research, data analysis, code work, infrastructure operations and " <>
            "multi-agent workflows."
      }
    ]
  end

  @doc """
  The manual's pages in the shape `pages/0` uses, one per slug at its `/docs`
  path, plus the page nginx answers a missing one with (`/docs-404`, which
  Traefik does not route, so it is only ever an error page).
  """
  def docs_pages do
    rendered = rendered_manual()
    nav = Site.Manual.nav()

    pages =
      for slug <- Site.Manual.slugs() do
        {:ok, %{title: title}} = Site.Manual.get(slug)

        %{
          path: Site.Manual.path_for_slug(slug),
          template: {:docs, %{nav: nav, slug: slug, body_html: Map.fetch!(rendered, slug)}},
          title: "Docs · " <> title,
          description: "#{title}, from the #{Site.Brand.engine()} manual."
        }
      end

    pages ++
      [
        %{
          path: "/docs-404",
          template: :docs_not_found,
          title: "Docs · Not found",
          description: "There is no page of the #{Site.Brand.engine()} manual at this address."
        }
      ]
  end

  @doc """
  Every page of the manual, rendered: `slug => html` for the article body.
  Rendering highlights every fence, which is most of the build's time, so it
  is done once per VM and kept for the build and the tests.
  """
  def rendered_manual do
    case :persistent_term.get({__MODULE__, :rendered_manual}, nil) do
      nil ->
        rendered =
          Site.Manual.slugs()
          |> Task.async_stream(
            fn slug ->
              {:ok, %{body: body}} = Site.Manual.get(slug)
              {slug, Site.Markdown.to_html(body)}
            end,
            timeout: :infinity
          )
          |> Map.new(fn {:ok, pair} -> pair end)

        :persistent_term.put({__MODULE__, :rendered_manual}, rendered)
        rendered

      rendered ->
        rendered
    end
  end

  @doc "The manual's search index, as `/docs/search-index.json` serves it."
  def search_index_json do
    rendered_manual() |> Site.Manual.search_index() |> Jason.encode!()
  end

  @doc "Where a served path lands on disk, relative to the output directory."
  def file_for("/"), do: "index.html"
  def file_for("/" <> rest), do: rest <> ".html"

  @doc "One page, rendered whole."
  def render(%{template: template} = page) do
    # Function components called by hand rather than from HEEx: the
    # `__changed__: nil` key is what tells `assign/3` there is no diff to track.
    inner =
      case template do
        {:docs, assigns} -> Site.DocsPages.show(Map.put(assigns, :__changed__, nil))
        :docs_not_found -> Site.DocsPages.not_found(%{__changed__: nil})
        template -> apply(Site.Pages, template, [%{__changed__: nil}])
      end

    shell = Site.Layouts.shell(%{__changed__: nil, inner_content: inner})

    %{
      __changed__: nil,
      page_title: page.title,
      meta_description: page.description,
      path: page.path,
      inner_content: shell
    }
    |> Site.Layouts.root()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc "Render every page and the manual, and copy the assets, into `out`."
  def run(out \\ "dist") do
    File.rm_rf!(out)
    File.mkdir_p!(out)

    for page <- pages() ++ docs_pages() do
      write!(out, file_for(page.path), render(page))
    end

    write!(out, "docs/search-index.json", search_index_json())

    for {file, body} <- Site.Llms.files() do
      write!(out, file, body)
    end

    site = Path.join(out, "site")
    File.mkdir_p!(site)

    for {source, published} <- Site.Assets.stylesheets() do
      File.cp!(source, Path.join(out, published))
    end

    File.cp_r!(Path.join(Site.Assets.priv(), "images"), Path.join(site, "images"))
    :ok
  end

  defp write!(out, file, body) do
    path = Path.join(out, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end
end
