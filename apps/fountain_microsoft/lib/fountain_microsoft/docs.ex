defmodule FountainMicrosoft.Docs do
  @moduledoc """
  This extension's slice of the manual, embedded at its own compile time
  (ADR 0043, ADR 0054).

  The same `Managoat.Docs` macro `Fountain.Docs` uses, over this app's `docs/`
  rather than the repository's. `Fountain.Manual` merges the two, so the page
  here is served at the URL it had while it lived in core — the mount is the
  host's `/docs` and the slug comes from the path under `docs/`, so
  `docs/catalog/connections/microsoft.md` is `/docs/catalog/connections/microsoft`
  on both sides of the move.

  Embedding here is what makes a core distribution's manual *complete* rather
  than pruned: an image without this application has neither the page nor a
  nav entry naming it, and no core page links to it.
  """

  use Managoat.Docs,
    root: Path.expand("../..", __DIR__),
    docs_dir: "docs",
    nav: "docs/nav.yml",
    # The host's mount. `Fountain.Manual.validate/1` refuses any other, because
    # a page at a mount nothing routes is a page nobody can find.
    mount: "/docs"
end
