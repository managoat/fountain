defmodule Fountain.Docs do
  @moduledoc """
  The public documentation manual (`docs/` at the repo root), embedded at
  compile time so the app can serve it at `/docs`.

  An instance of `Managoat.Docs`: this module is the `use` line and nothing
  else. The macro reads `docs/nav.yml` and every page it names in this
  module's body, so each is an `@external_resource` here (an edit recompiles
  this module in dev), preprocesses the pages to plain markdown with
  `Managoat.Docs.Compiler`, and generates `nav/0`, `get/1`, `slugs/0`,
  `search_index/0`, `search_index_json/0`, `path_for_slug/1`,
  `external_resources/0` and `languages/0`. `FountainWeb.DocsController`
  renders a page through `Managoat.Docs.Markdown.to_trusted_html/1`, the
  same pipeline as `/help`.

  `/docs` is the only place this manual is published. It used to be built as a
  static MkDocs Material site and deployed to GitHub Pages as well; that second
  copy was retired once `/docs` served the same markdown from the same nav,
  because two publishing paths for one set of pages is two things to keep
  green (#1008). Compile-time embedding is also what ships the content: the
  release image never contains `docs/` itself, only these strings in the beam
  file, ~525 KB of markdown, ~737 KB once snippet includes (the changelog
  pulls in the repo-root `CHANGELOG.md`) are expanded.

  This is distinct from `Fountain.Help`, the curated in-app help under
  `priv/help/`; that stays as it is, and `/docs` is the full public manual.

  The nav is **read from `docs/nav.yml` at compile time**, not mirrored here.
  It used to be a hand-maintained copy that `docs_test.exs` diffed against the
  real file, and the diff is what people hit: adding a page without editing
  this module failed a test in CI partition 3, which looks entirely unrelated
  to the docs. Adding a page to `docs/nav.yml` is now the whole change.

  The markdown dialect the preprocessing covers is deliberately small (snippet
  includes, admonitions, relative `.md` links); if a doc page starts using
  something beyond that, check the page at `/docs`, don't assume. Nothing
  renders these pages but this module, so there is no second renderer to
  disagree with. The structural guardrails (`docs_test.exs`) come from
  `Managoat.Docs.GuardrailCase`.
  """

  use Managoat.Docs,
    root: Path.expand("../../../..", __DIR__),
    docs_dir: "docs",
    nav: "docs/nav.yml",
    mount: "/docs",
    # docs/changelog.md pulls the repo-root CHANGELOG.md in via a snippet.
    extra_resources: ["CHANGELOG.md"],
    # The languages whose tree-sitter parsers the Dockerfile bakes into the
    # image before `mix release` (Lumis cannot fetch one at runtime on a
    # read-only root filesystem, #879). `python` and `javascript` joined the
    # list with the webhooks reference (#700), which carries a signature
    # verifier in each; `toml` joined with the Fly guide, the first page to
    # quote a `fly.toml`, since `ini` highlights the wrong things for it.
    # docs_test.exs fails if the corpus or priv/help grows a fence in a
    # language this list does not name.
    languages: ~w(bash typescript javascript python json json5 yaml toml elixir ini)
end
