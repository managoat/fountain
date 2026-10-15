# managoat.com

The pages at [managoat.com](https://managoat.com): the home page and
`/built-with`, the list of apps built on the API. Two pages, rendered to
static HTML and served by nginx on the same host as the maintainer's Fountain
instance.

They started as Phoenix templates in the server. From 2026-09-14 they lived
in their own repository, [managoat/site](https://github.com/managoat/site),
and on 2026-10-15 they came back here as this directory. They are still a
static build with their own image, not templates in the app. ADR 0034's
2026-10-15 amendment says why.

## How it works

- `lib/site/pages/*.html.heex` are the pages, `lib/site/pages.ex` the data
  they render, `lib/site/layouts/` the header, the footer and the `<head>`.
- `Site.Brand` holds the constants: the name, the asset bundle, and who to
  contact. There is no sign-up and no price. Every call to action is
  `Site.Brand.contact_url/0`, a mail to Jake, and the tests fail if a page
  links `/auth/register` or `/auth/login`.
- `mix site.build` renders everything into `dist/`, and `mix test` checks it.
  The link test checks every `/docs` link against `../docs/nav.yml` and the
  pages on disk, so a renamed manual page fails here, in the same PR.
- The `site` job in `.github/workflows/ci.yml` runs these tests and the
  render on a pull request that touches `site/` or `docs/`, as part of
  `CI required`, and on every push to `main`. On a push to `main` that
  touches `site/`, it then calls `.github/workflows/site.yml` with the
  render, which builds `ghcr.io/managoat/site` for both architectures and
  publishes `k8s/`, with that image pinned in `deployment.yaml`, as the OCI
  artifact `ghcr.io/managoat/site-manifests`, which Flux in home-cloud
  deploys.
- Traefik routes the site's paths on `managoat.com` here, and everything else
  (`/docs`, `/auth`, the console, the API) to the app. `k8s/ingressroute.yaml`
  is that list.

## Working on it

The toolchain is the repository's, from the root `.tool-versions`.

```bash
cd site
mix deps.get
mix test
mix site.build && python3 -m http.server -d dist 8000
```

To add a page, add a template under `lib/site/pages/`, a row in
`Site.Build.pages/0`, and its path in `k8s/ingressroute.yaml`. The tests fail
until all three agree.

## What stays in the app

On any other deployment of Fountain, the app's `/` redirects to the console.
On managoat.com, Traefik sends `/` here instead. Everywhere, the app serves the
operator's legal pages at `/terms` and `/privacy`, and the manual at `/docs`.
The pages cut on 2026-10-15 (`/oss-launch`, `/integrations`, `/self-hosted`,
`/faq`, `/code-review-bot` and the case study) are no longer routed here, so
the app answers them with 404.
