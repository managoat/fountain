# managoat.com

The pages at [managoat.com](https://managoat.com): the home page,
`/built-with` (the list of apps built on the API), and the manual at `/docs`
with its llms.txt files. Rendered to static HTML and served by nginx on the
same host as the maintainer's Managoat instance.

The two site pages started as Phoenix templates in the server. From
2026-09-14 they lived in their own repository,
[managoat/site](https://github.com/managoat/site), and on 2026-10-15 they came
back here as this directory, still a static build with its own image (ADR
0034's 2026-10-15 amendment). The manual joined them the same day: the server
used to compile `docs/` in and serve it, and now only redirects to it (ADR
0081).

## How it works

- `lib/site/pages/*.html.heex` are the pages, `lib/site/pages.ex` the data
  they render, `lib/site/layouts/` the header, the footer and the `<head>`.
- `Site.Brand` holds the constants: the name, the icons (the server's
  bundle, copied into `priv/site/images/brand/`), and who to contact. There is no sign-up and no price. Every call to action is
  `Site.Brand.contact_url/0`, a mail to Jake, and the tests fail if a page
  links `/auth/register` or `/auth/login`.
- The manual: `Site.Manual` reads `../docs/nav.yml` and the pages it names
  and expands the authoring dialect (snippet includes, admonitions, relative
  `.md` links); `Site.Markdown` renders it, sanitised, with fenced code
  highlighted by Lumis at build time; `Site.DocsPages` is the page shell
  (sidebar, search, copy buttons); `Site.Llms` writes `/llms.txt`,
  `/llms-full.txt` and the skill (`priv/llms/SKILL.md`). They are what was
  left of the `managoat_docs` library once it had one consumer.
- `mix site.build` renders everything into `dist/`: `index.html`,
  `built-with.html`, `docs.html` and `docs/<slug>.html` for the manual,
  `docs-404.html`, `docs/search-index.json`, `llms.txt`, `llms-full.txt`,
  `skill.txt`, `skills/managoat/SKILL.md` and, at the skill's old path,
  `skills/fountain/SKILL.md`. A fence in a language Lumis
  cannot highlight fails the build.
- `mix test` checks it: the site's links (every `/docs` link is a page of the
  manual), the manual's structure (nav both ways, links, anchors, snippets,
  fenced languages, the search index), its content tests, the renderer
  against hostile markdown, and the llms files. These were the server's
  `docs_test.exs` and its docs and llms controller tests.
- The `site` job in `.github/workflows/ci.yml` runs these tests and the
  render on a pull request that touches `site/`, `docs/` or a file the manual
  includes (`MANUAL_SOURCES` in `scripts/ci/changes.py`), as part of
  `CI required`, and on every push to `main`. On a push to `main` that changed
  what it renders, it then calls `.github/workflows/site.yml` with the render,
  which builds `ghcr.io/managoat/site` for both architectures and publishes
  `k8s/`, with that image pinned in `deployment.yaml`, as the OCI artifact
  `ghcr.io/managoat/site-manifests`, which Flux in home-cloud deploys. So a
  docs fix is live on managoat.com minutes after its merge, with no release.
- Traefik routes the site's paths on `managoat.com` here, and everything else
  (`/auth`, the console, the API and its `/api/docs`) to the app.
  `k8s/ingressroute.yaml` is that list.

## Working on it

The toolchain is the repository's, from the root `.tool-versions`.

```bash
cd site
mix deps.get
mix test
mix site.build && python3 -m http.server -d dist 8000
```

`http.server` serves files as named: open `/docs.html` or
`/docs/quickstart.html`, where nginx would serve `/docs` and
`/docs/quickstart`.

To add a page, add a template under `lib/site/pages/`, a row in
`Site.Build.pages/0`, and its path in `k8s/ingressroute.yaml`. The tests fail
until all three agree. A manual page is a file under `docs/` and a line in
`docs/nav.yml`; contributing/docs.md has the rules.

## What stays in the app

On any other deployment of Managoat, the app's `/` redirects to the console,
and `/docs`, `/docs/*`, `/llms.txt`, `/llms-full.txt`, `/skill` and
`/skills/managoat/SKILL.md` (and `/skills/fountain/SKILL.md`) answer 301 to the same path at `DOCS_URL`
(managoat.com by default). On managoat.com, Traefik sends all of those here
instead. Everywhere, the app serves the operator's legal pages at `/terms`
and `/privacy`. The pages cut on 2026-10-15 (`/oss-launch`, `/integrations`,
`/self-hosted`, `/faq`, `/code-review-bot` and the case study) are no longer
routed here, so the app answers them with 404.
