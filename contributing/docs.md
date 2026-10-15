# Writing the manual

`docs/` is the public manual, published at
[managoat.com/docs](https://managoat.com/docs) and nowhere else. This page is
the one place the guardrails around it are written down; CLAUDE.md and
CONTRIBUTING.md link here rather than repeating them.

## How a page is published

`site/` builds it (ADR 0081). `mix site.build` reads `docs/nav.yml` and every
page it names (`Site.Manual`), renders them through a sanitising markdown
pipeline with fenced code highlighted at build time (`Site.Markdown`), and
writes one HTML page per slug, `/docs/search-index.json`, and `/llms.txt`,
`/llms-full.txt` and `/skill` (`Site.Llms`). nginx serves the result on
managoat.com beside the home page. The server does not serve the manual: an
instance's `/docs` and llms paths redirect to `DOCS_URL`.

A merge to `main` that changes `docs/`, or a file a page includes, republishes
the site through `site-publish` and Flux. It does not wait for a release, so
the manual describes `main`; `docs/index.md` says so to readers.

There is exactly one publisher. The MkDocs Material site and its GitHub
Pages copy were retired in #1008, and the redirect tombstone that answered
the old URLs died with the move to the `managoat` organization (GitHub Pages
does not follow a transfer redirect; #1814 deleted its generator). Do not
build a second one; ADR 0034 is the standing decision.

The dialect the renderer understands is small (snippet includes,
admonitions, relative `.md` links) and is inherited from the MkDocs site.
Check a page if it uses anything fancier:

```bash
cd site && mix site.build && python3 -m http.server -d dist 8000
```

`http.server` does not map `/docs/x` to `docs/x.html` the way nginx does;
open `http://localhost:8000/docs/x.html`.

## Checks for documentation changes

| Change | CI checks |
|---|---|
| `CLAUDE.md`, `CONTRIBUTING.md`, `SETUP.md`, `scripts/ci/README.md`, Markdown under `contributing/` or `decisions/` | Repository policy and conflict-marker checks, plus the secret scan |
| `README.md`, `CHANGELOG.md` or `docs/` | The `site` job: the manual's render and its structural and content tests |
| A file a page includes or a manual test reads: the first-request snippets in `apps/fountain/priv/first_request/`, `sdk/typescript/examples/`, `deploy/k8s/prometheusrule.yaml` | The `site` job, beside whatever else the path selects (those are code paths, so the full server plan too) |
| The SDK's `README.md` or its page under `docs/` | The TypeScript SDK check, which runs on every plan; published pages also get the manual tests |
| `docs/cli.md` or `docs/cli/` | Manual tests and the CLI reference parity checks (the `docs` job) |
| `site/` (the managoat.com pages and the manual's renderer) | The `site` job in `ci.yml` only |
| Code, configuration, unregistered paths, or mixed code/documentation changes | Full server validation and the TypeScript SDK check |

The short paths apply to pull requests. Main always runs full CI, and so
does a manual CI dispatch. ADRs retain their separate OKF validation and index check.
Non-Markdown decision evidence and executable files still select full server
validation. Alert fixtures run on full plans, including main and manual runs;
docs-only plans skip their evaluator. The TypeScript SDK job still runs on
every plan.

For contributor-only Markdown, run:

```bash
python3 scripts/conflict-markers.py
git diff --check
```

For published manual changes, use the pinned toolchain and run:

```bash
cd site && mix test
```

This runs the manual's suites (navigation, rendering, links, anchors, fenced
languages, the search index, the llms files) and the site's own. It needs no
database and does not compile the server. `README.md` participates because
its diagram text has a manual test.

For CLI reference changes, also run:

```bash
go -C cli test -count=1 ./internal/cmd -run 'TestEveryCommandIsDocumented|TestNoDocumentedCommandIsInvented|TestGeneratedCLIReferenceIsCurrent'
```

For SDK documentation, run that client's checks from
[scripts/ci/README.md](../scripts/ci/README.md#sdk-jobs).
For code, tooling or mixed changes, use the component checks in
[CONTRIBUTING.md](../CONTRIBUTING.md#before-you-push).

## Structural rules

- **The nav lives only in `docs/nav.yml`.** `Site.Manual` parses the
  `nav:` block when the site builds. Keep to the two line shapes the parser
  reads (`- Title: x.md` for a page, `- Header:` for a category or a
  section); a line it cannot read fails the build.
- **The sidebar is the four Diátaxis categories, three levels deep.** After
  the home page come Tutorials, How-to guides, Explanation and Reference, at
  a 2-space indent. A category holds pages and sections at 6 spaces, and a
  section holds pages only, at 10. Any other indent, a section inside a
  section, a line indented past the entry above it, or a header with nothing
  under it raises. File a page by what its reader is doing: following a
  lesson, doing one task, understanding why, or looking something up. A
  how-to that lives in `catalog/` still goes under How-to guides. The nav
  decides only the sidebar: a page's URL comes from its path under `docs/`,
  so moving it between categories changes no link.
- **A page not in the nav is published nowhere.** The test walks
  `docs/**/*.md` both ways: every page the nav names exists, and every page
  on disk is named. There is no allowlist. A markdown file that should not be
  read at `/docs` belongs somewhere else; `decisions/` and
  `contributing/` are deliberately unpublished.
- **Links and anchors are checked.** Every internal `/docs` link must resolve
  to a page, and every `#anchor` to a heading id on the rendered page. The
  checks are in `site/test/manual_test.exs`.
- **Every fence names a language that highlights.** A fence must name a
  Lumis language, by id or alias, or one of the plaintext names in
  `Site.Markdown` (`text`, `promql`, ...). Anything else fails the build,
  because Lumis renders an unknown language plain without complaint.
- **A snippet include outside `docs/` must be a path CI watches.** A page
  can include any file in the repository (`--8<-- "CHANGELOG.md"`), but the
  `site` job only runs, and the site only republishes, when what it reads
  changes. A new include outside `docs/` goes on `MANUAL_SOURCES` in
  `scripts/ci/changes.py` and the publish path list in the `site` job of
  `ci.yml`; a manual test fails until the first is done.
- **`docs/cli.md` is diffed against the CLI.** `cli/internal/cmd/docs_test.go`
  fails if a command exists that the page does not mention, or the reverse.
  Add a CLI command, add it to `docs/cli.md` in a fenced `bash` block.

## Writing guidance (optional)

Write for developers learning Fountain's model. Prefer concrete examples,
accurate commands, and explanations of defaults and failure cases. Use the
[glossary](../docs/reference/glossary.md) for product terms: an Agent is stored
configuration, a Conversation is a run, a runtime is the coding-agent CLI,
and a sandbox is its isolated machine. Distinguish an Environment from
process environment variables and deployment tiers. Explain that a Fountain
Vault supplies overrides that win over an Environment.

Choose punctuation and sentence structure for clarity. There are no prose
linters or required style reports.

## Public GitHub links (manual)

Run this when checking the manual's external references:

```bash
python3 scripts/ci/check_external_links.py
```

It checks public GitHub links in the manual and CLAUDE.md.
Network availability and remote link changes do not block merge CI. Internal
links and anchors remain part of the structural tests above.

## The changelog is a docs page

`CHANGELOG.md` is published at `/docs/changelog` (`docs/changelog.md`
includes it), which is why its links are absolute URLs: a relative link
would resolve under `/docs`. It is frozen as of 2026-10-15; later
release notes are on GitHub Releases
([CONTRIBUTING.md](../CONTRIBUTING.md#release-notes)).
