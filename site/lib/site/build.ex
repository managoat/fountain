defmodule Site.Build do
  @moduledoc """
  Renders every page to `dist/` and copies the assets beside them.

  A page is a path, the template that renders it, and the title and
  description its card carries; the table is the one the app's
  `MarketingController` used to hold, one clause per action. Output file
  names follow the served path with `.html` appended (`/built-with` →
  `built-with.html`) and `/` is `index.html`, which is the shape
  `nginx.conf`'s `try_files` serves without a redirect.

  Two pages since 2026-10-15. The launch page, the case study, the code review
  bot, self-host, the questions page and integrations were cut; what was worth
  keeping from the last three moved into the manual
  (`docs/self-hosting.md`, `docs/reference/security.md`,
  `docs/integrations/editors.md`).
  """

  @site_title "Claude Code, Codex and Gemini CLI behind one API"

  @doc "The description a page uses when it sets none: the pitch."
  def default_description do
    "#{Site.Brand.name()} is a conversational API to a computer, built on the " <>
      "open-source #{Site.Brand.engine()} server. The machine arrives with your " <>
      "repositories and credentials and keeps its work between prompts."
  end

  @doc "Every page the site publishes."
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

  @doc "Where a served path lands on disk, relative to the output directory."
  def file_for("/"), do: "index.html"
  def file_for("/" <> rest), do: rest <> ".html"

  @doc "One page, rendered whole."
  def render(%{path: path, template: template, title: title, description: description}) do
    # Function components called by hand rather than from HEEx: the
    # `__changed__: nil` key is what tells `assign/3` there is no diff to track.
    inner = apply(Site.Pages, template, [%{__changed__: nil}])
    shell = Site.Layouts.shell(%{__changed__: nil, inner_content: inner})

    %{
      __changed__: nil,
      page_title: title,
      meta_description: description,
      path: path,
      inner_content: shell
    }
    |> Site.Layouts.root()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  @doc "Render every page and copy the assets into `out`."
  def run(out \\ "dist") do
    File.rm_rf!(out)
    File.mkdir_p!(out)

    for page <- pages() do
      file = Path.join(out, file_for(page.path))
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, render(page))
    end

    site = Path.join(out, "site")
    File.mkdir_p!(site)

    for {source, published} <- Site.Assets.stylesheets() do
      File.cp!(source, Path.join(out, published))
    end

    File.cp_r!(Path.join(Site.Assets.priv(), "images"), Path.join(site, "images"))
    :ok
  end
end
