defmodule Site.Build do
  @moduledoc """
  Renders every page to `dist/` and copies the assets beside them.

  A page is a path, the template that renders it, and the title and
  description its card carries; the table is the one the app's
  `MarketingController` used to hold, one clause per action. Output file
  names follow the served path with `.html` appended (`/faq` →
  `faq.html`) and `/` is `index.html`, which is the shape `nginx.conf`'s
  `try_files` serves without a redirect.
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
    engine = Site.Brand.engine()

    [
      %{
        path: "/",
        template: :home,
        title: "#{@site_title} · #{brand}",
        description: default_description()
      },
      %{
        path: "/oss-launch",
        template: :oss_launch,
        title: "A conversational API to a computer · #{engine}",
        description:
          "Give your app a computer it can talk to. Build on #{engine}, " <>
            "run the open-source stack yourself, and keep your data, keys and agents " <>
            "under your control."
      },
      %{
        path: "/integrations",
        template: :integrations,
        title: "Coding agent integrations · #{brand}",
        description:
          "Run coding agents from your editor, chat app or code on sandboxes " <>
            "that keep their work between messages."
      },
      %{
        path: "/faq",
        template: :faq,
        title: "Questions · #{brand}",
        description:
          "What a developer and a security reviewer ask about #{brand}: model " <>
            "keys, what a sandbox does between messages, tenant isolation, what " <>
            "it does not have, and what it takes to run the whole thing yourself."
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
      },
      # Unlisted: nothing links here, on purpose. The handler the page shows
      # has never been run against a live webhook, and an unrun program is not
      # something to put in the footer. `test/site_test.exs` asserts the absence.
      %{
        path: "/code-review-bot",
        template: :code_review_bot,
        title: "A code review bot · #{brand}",
        description:
          "A pull request opens, GitHub posts a webhook, and one API call starts " <>
            "an agent that already has the checkout. The whole program is on the " <>
            "page: no runner pool, no queue, no container image per repository."
      },
      %{
        path: "/self-hosted",
        template: :self_hosted,
        title: "Self-host #{engine} · #{brand}",
        description:
          "Run #{engine} on your infrastructure with the same API, " <>
            "SDK and CLI. Own the database, keys and sandboxes. Start with Docker " <>
            "Compose or Kubernetes, with no license key or seat count."
      },
      %{
        path: "/case-studies/self-healing-infrastructure",
        template: :case_study_self_healing,
        title: "Kubernetes alert to pull request in 4m 27s · #{brand}",
        description:
          "A real Kubernetes incident from alert to pull request in 4m 27s. The agent " <>
            "held no cluster credentials, and a human kept the only approval."
      }
    ]
  end

  @doc "The paths nginx answers with a redirect rather than a file."
  def redirects, do: %{"/case-studies" => "/case-studies/self-healing-infrastructure"}

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
