defmodule SiteTest do
  use ExUnit.Case, async: true

  @out Path.join(System.tmp_dir!(), "managoat-site-test-#{System.unique_integer([:positive])}")

  setup_all do
    Site.Build.run(@out)
    on_exit(fn -> File.rm_rf!(@out) end)
    pages = for page <- Site.Build.pages(), into: %{}, do: {page.path, read(page.path)}
    %{pages: pages}
  end

  defp read(path), do: File.read!(Path.join(@out, Site.Build.file_for(path)))

  # The manual is part of this build, so a link into it is checked against
  # the manual's own slugs.
  defp docs_slugs, do: MapSet.new(Site.Manual.slugs())

  test "every page renders with its title and card", %{pages: pages} do
    for page <- Site.Build.pages() do
      html = pages[page.path]
      assert html =~ "<title>#{page.title}</title>", page.path
      assert html =~ ~s(<meta name="description" content="#{page.description}">), page.path
      assert html =~ ~s(<link rel="canonical" href="https://managoat.com#{page.path}">), page.path
      assert html =~ ~s(data-skin="paper")
      refute html =~ ~r|href="/docs"\s+aria-current="page"|
    end
  end

  test "nothing the app resolved at request time leaked through", %{pages: pages} do
    for {path, html} <- pages do
      refute html =~ "FountainWeb", path
      refute html =~ "Fountain.Brand", path
      refute html =~ "{{", path
      refute html =~ "csrf-token", path
      refute html =~ "phoenix_live_view", path
    end
  end

  # Fountain retired its OpenAI-compatible and AG-UI endpoints (fountain ADR
  # 0057), and production answers them 404 and 406. A page that still shows one
  # is an instruction that cannot work. This pins the endpoints, the flag and
  # the client package rather than the names.
  test "no page offers a retired Fountain endpoint", %{pages: pages} do
    for {path, html} <- pages,
        gone <- ["/v1/chat/completions", "/v1/models", "/api/agui", "openai_compat", "@ag-ui/"] do
      refute html =~ gone, "#{path} still shows #{gone}"
    end
  end

  # Fountain has had no product analytics since 2026-10-12 (fountain ADR 0025,
  # Retired), and the site loaded PostHog until 2026-10-15. No page loads it,
  # configures it, or names its hosts.
  test "no page loads analytics", %{pages: pages} do
    for {path, html} <- pages do
      refute html =~ ~r/posthog/i, "#{path} still mentions PostHog"
    end
  end

  # The dashboard is for existing accounts; it does not advertise hosted sign-up.
  test "no page sells the hosted instance", %{pages: pages} do
    for {path, html} <- pages do
      refute html =~ "/auth/register", "#{path} links the sign-up"
      refute html =~ "/auth/login", "#{path} links the sign-in"
      refute html =~ ~r/\$\d/, "#{path} quotes a price"
      refute html =~ ~r/free credit|first agent free/i, "#{path} offers free credit"
      assert html =~ ~s(href="/dashboard"), "#{path} has no dashboard link"
      refute html =~ "Contact #{Site.Brand.contact_name()}"
    end
  end

  # The project is Managoat (ADR 0082). Until then the pages called Managoat a
  # hosted instance that "runs on Fountain", the engine; there is no such split
  # any more, and the icons are this site's own files, not another host's.
  test "no page splits the name into a product and an engine", %{pages: pages} do
    for {path, html} <- pages do
      refute html =~ ~r/runs on Fountain|built on (the open-source )?Fountain|hosted Fountain/i,
             "#{path} still describes Managoat as running on Fountain"

      refute html =~ "share.files.inevitable.fyi", "#{path} hot-links the icons"
    end

    for name <- Site.Brand.assets() do
      assert File.exists?(Path.join(@out, Site.Brand.asset(name))), "#{name} is not in the build"
    end
  end

  test "the homepage does not send readers into the Conversations demo", %{pages: pages} do
    refute pages["/"] =~ "fountain-conversations.demo.managoat.com"
    refute pages["/"] =~ "Open Conversations"
  end

  # Every same-host link: a page of the site, one of its assets, or a page of
  # the manual. Until 2026-10-15 a `/docs` link was let through unchecked here
  # (a separate task asked the live host), which is how five dead links into
  # the manual got in. Only /dashboard is an allowed server destination.
  test "every internal link lands on a page, an asset, or a page of the manual",
       %{pages: pages} do
    site_paths = Enum.map(Site.Build.pages(), & &1.path)
    docs = docs_slugs()

    for {path, html} <- pages,
        [href] <- Regex.scan(~r/href="(\/[^"?]*)/, html, capture: :all_but_first) do
      cond do
        href == "/docs" or String.starts_with?(href, "/docs/") ->
          # A heading id is an implementation detail of the page's markdown;
          # the site's own pages link the page, and the manual's anchors are
          # checked by manual_test.exs.
          refute href =~ "#", "#{path} links #{href}: link a page of the manual, not a heading"
          slug = href |> String.replace_prefix("/docs", "") |> String.trim("/")
          assert slug in docs, "#{path} links #{href}, which is not a page of the manual"

        href == "/dashboard" ->
          :ok

        String.starts_with?(href, "/site/") ->
          assert File.exists?(Path.join(@out, href)), "#{path} links #{href}, which is not built"

        true ->
          href = href |> String.replace(~r/#.*/, "") |> String.trim_trailing("/")
          href = if(href == "", do: "/", else: href)
          assert href in site_paths, "#{path} links #{href}, which nothing serves"
      end
    end
  end

  test "the roster's links are absolute and no app is listed twice" do
    apps = Site.Pages.built_apps_flat()
    ids = Enum.map(apps, & &1.id)
    assert ids == Enum.uniq(ids)

    for app <- apps, link <- [app.url, app.source] do
      assert String.starts_with?(link, "https://"), "#{app.id}: #{link}"
    end
  end

  test "the assets every page links are in the build" do
    for {_source, published} <- Site.Assets.stylesheets() do
      assert File.exists?(Path.join(@out, published)), published
    end

    for path <- ~w(conversations workbench workbench-mobile) do
      assert File.exists?(Path.join(@out, "site/images/apps/#{path}.jpg"))
    end
  end

  test "Traefik sends every page, the manual and the assets to the site" do
    rule = File.read!(Path.expand("../k8s/ingressroute.yaml", __DIR__))
    exact = Regex.scan(~r/Path\(`([^`]+)`\)/, rule, capture: :all_but_first) |> List.flatten()

    prefixes =
      Regex.scan(~r/PathPrefix\(`([^`]+)`\)/, rule, capture: :all_but_first) |> List.flatten()

    routed? = fn path -> path in exact or Enum.any?(prefixes, &String.starts_with?(path, &1)) end

    for page <- Site.Build.pages(), do: assert(routed?.(page.path), "#{page.path} is not routed")

    assert "/site/" in prefixes

    # The manual and its machine-readable side (decisions/0081). An instance's
    # own /docs redirects here, so on managoat.com these must never reach the
    # app: it would redirect them back to itself.
    for slug <- Site.Manual.slugs(),
        do: assert(routed?.(Site.Manual.path_for_slug(slug)), "/docs/#{slug} is not routed")

    for {file, _body} <- Site.Llms.files(),
        file != "skill.txt",
        do: assert(routed?.("/" <> file), "/#{file} is not routed")

    for path <- ~w(/skill /docs/search-index.json /docs/), do: assert(routed?.(path), path)

    # And nothing the app must keep: the rule is a carve-out, not a takeover.
    for path <-
          ~w(/api/docs /docsx /docs-404 /auth/login /dashboard /api/health /terms /privacy /health /help),
        do: refute(routed?.(path), "#{path} would leave the app")

    # The pages cut on 2026-10-15 belong to the app again, which answers them
    # 404 (its front_door tests pin that).
    for path <- ~w(/oss-launch /integrations /self-hosted /faq /code-review-bot /case-studies),
        do: refute(routed?.(path), "#{path} was cut but is still routed to the site")
  end

  test "nginx redirects by path, never to its own port" do
    conf = File.read!(Path.expand("../nginx.conf", __DIR__))
    assert conf =~ "absolute_redirect off;"
  end
end
