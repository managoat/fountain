# Writing the manual

`docs/` is the public manual, published at `/docs` and nowhere else. This
page is the one place the guardrails around it are written down; CLAUDE.md
and CONTRIBUTING.md link here rather than repeating them.

## How a page is published

The markdown is embedded at compile time by `Fountain.Docs`, one `use` line
over the `managoat_docs` library (ADR 0037). The macro embeds the pages,
`Managoat.Docs.Markdown` renders them (the sanitising pipeline that `/help`
and agent output share; it returns a binary, callers `Phoenix.HTML.raw/1`
it), and `docs_test.exs` takes its structural checks from
`Managoat.Docs.GuardrailCase`.

There is exactly one publisher. The MkDocs Material site and its GitHub
Pages copy were retired in #1008, and the redirect tombstone that answered
the old URLs died with the move to the `managoat` organization (GitHub Pages
does not follow a transfer redirect; #1814 deleted its generator). Do not
build a second one; ADR 0034 is the standing decision.

The dialect the renderer understands is small (snippet includes,
admonitions, relative `.md` links) and is inherited from the MkDocs site.
Check a page at `/docs` if it uses anything fancier: start the server and
open the route.

## Checks for documentation changes

| Change | CI checks |
|---|---|
| `CLAUDE.md`, `CONTRIBUTING.md`, `SETUP.md`, `scripts/ci/README.md`, Markdown under `contributing/`, `standards/`, `decisions/` or `changelog.d/` | Repository policy, changelog and conflict-marker checks, plus the secret scan |
| `README.md`, `CHANGELOG.md` or `docs/` | Core rendering and structural tests |
| The SDK's `README.md` or its page under `docs/` | The TypeScript SDK check, which runs on every plan; published pages also get the manual tests |
| `docs/cli.md` or `docs/cli/` | Manual tests and the CLI reference parity checks |
| Code, configuration, unregistered paths, or mixed code/documentation changes | Full server validation and the TypeScript SDK check |

The short paths apply to pull requests and merge groups. Main reuses a tested
tree when possible; otherwise it runs full CI. A manual CI dispatch also runs
full validation. ADRs retain their separate OKF validation and index check.
Non-Markdown decision evidence and executable files still select full server
validation. Alert fixtures run on full plans, including main and manual runs;
docs-only plans skip their evaluator. The TypeScript SDK job still runs on
every plan unless the tree is reused.

For contributor-only Markdown, run:

```bash
python3 scripts/conflict-markers.py
python3 scripts/changelog.py check
git diff --check
```

For published manual changes, use the pinned toolchain and run:

```bash
bash scripts/test-docs.sh
```

This runs the manual's documentation suites, including navigation, rendering
and links. It needs the usual migrated test database. `README.md` participates
because its diagram text has a docs test.

For CLI reference changes, also run:

```bash
go -C cli test -count=1 ./internal/cmd -run 'TestEveryCommandIsDocumented|TestNoDocumentedCommandIsInvented|TestGeneratedCLIReferenceIsCurrent'
```

For SDK documentation, run that client's checks from
[scripts/ci/README.md](../scripts/ci/README.md#sdk-jobs).
For code, tooling or mixed changes, use the component checks in
[CONTRIBUTING.md](../CONTRIBUTING.md#before-you-push).

## Structural rules

- **The nav lives only in `docs/nav.yml`.** `Fountain.Docs` parses the
  `nav:` block at compile time. Keep to the two line shapes the parser reads
  (`  - Title: x.md`, and `  - Section:` with six-space-indented children);
  a line it cannot read raises at compile time. **Sections are one level
  deep**: the sidebar renders a section and its pages, so a sub-section, or a
  page indented past its siblings, raises too. Flatten it into a sibling
  section (`Catalog` is the model) or make it headings on a hub page.
- **A page not in the nav is published nowhere.** The test walks
  `docs/**/*.md` both ways: every page the nav names exists, and every page
  on disk is named. There is no allowlist. A markdown file that should not be
  read at `/docs` belongs somewhere else; `decisions/`, `standards/` and
  `contributing/` are deliberately unpublished.
- **Links and anchors are checked.** Every internal `/docs` link must resolve
  to a page, and every `#anchor` to a heading on that page. The checks are
  `Managoat.Docs.Checks`; the library runs the same template against a
  fixture manual, so a change to a check is tested there first.
- **Anything read at compile time must be `COPY`d into the Docker build
  stage.** The release image holds no `docs/`, only strings baked out of it,
  so a file outside the `COPY` list does not degrade to a broken link:
  `mix release` dies, no image is built, CI stays green and the deploy never
  happens (#884). The test asserts the module's `external_resources/0`
  against the Dockerfile. A file outside `docs/` goes on the
  `extra_resources:` line of `Fountain.Docs`, which is how `CHANGELOG.md` is
  declared.
- **`docs/cli.md` is diffed against the CLI.** `cli/internal/cmd/docs_test.go`
  fails if a command exists that the page does not mention, or the reverse.
  Add a CLI command, add it to `docs/cli.md` in a fenced `bash` block.
- **An extension may own pages** (ADR 0043, #1510). They live in
  `apps/<app>/docs/` with that app's own `nav.yml`, embedded by its own
  `use Managoat.Docs` module and merged into the sidebar by `Fountain.Manual`,
  which is what every renderer asks instead of `Fountain.Docs`. Sections
  merge by title. A core page must not link to an extension page: the core
  test walks the core manual alone, and a core-only distribution would carry
  a dead link. The extension's own suite runs the link checks over the merged
  manual. No extension ships pages today; the Google, Microsoft and Slack
  manuals left with those extensions (simplify 5/5).

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

It checks public GitHub links in the manual, extension manuals and CLAUDE.md.
Network availability and remote link changes do not block merge CI. Internal
links and anchors remain part of the structural tests above.

## The changelog is a docs page

`CHANGELOG.md` is served at `/docs/changelog`, which is why fragment links
are absolute URLs (a relative link would resolve under `/docs`) and why the
file is on the `extra_resources:` line. How fragments work is in
[`changelog.d/README.md`](../changelog.d/README.md).
