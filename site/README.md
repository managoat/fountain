# managoat.com

The pages of [managoat.com](https://managoat.com): the homepage, the
open-source launch page, integrations, built-with, self-host, the questions
page, the case study and the code review bot. Eight pages, rendered to static HTML and served by nginx
behind the same host as the product.

They used to be Phoenix templates inside
[managoat/fountain](https://github.com/managoat/fountain), rendered by the
server on every request. They moved here so the open-source engine does not
carry one deployment's sales copy, and so an edit to a headline does not run
the engine's test suite and rebuild its image.

## How it works

- `lib/site/pages/*.html.heex` are the pages, `lib/site/pages.ex` the data
  they render. Both came over from the fountain repo nearly verbatim.
- `lib/site/layouts/` is the header, the footer and the `<head>`.
- What the app read at request time is a constant here: `Site.Brand` (the
  name, the asset bundle, and who to contact).
- The hosted instance is not offered, so there is no pricing and no sign-up.
  Every call to action is `Site.Brand.contact_url/0`, a mail to Jake, and
  the tests fail if a page links `/auth/register` or `/auth/login`.
- `mix site.build` renders everything into `dist/`; `mix test` checks it;
  `mix site.check_links` asks managoat.com whether every link into the manual
  still answers.
- A push to `main` builds `ghcr.io/managoat/site`, pins the sha into
  `k8s/deployment.yaml`, and Flux in home-cloud rolls it. Traefik routes the
  site's paths on `managoat.com` here and everything else (`/docs`, `/auth`,
  the console, the API) to the app; `k8s/ingressroute.yaml` is that list.

## Working on it

```bash
mise install
mix deps.get
mix test
mix site.build && python3 -m http.server -d dist 8000
```

Adding a page: a template under `lib/site/pages/`, a row in
`Site.Build.pages/0`, and its path in `k8s/ingressroute.yaml`. The tests fail
until all three agree.

## What stays in the app

`/` on any other deployment of Fountain is a plain front door, `/terms` and
`/privacy` are the operator's legal pages, and `/docs` is the manual. None of
that is marketing, and all of it stays in the engine.
