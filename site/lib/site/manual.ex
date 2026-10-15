defmodule Site.Manual do
  @moduledoc """
  The manual: `docs/` at the repository root, read and preprocessed into
  plain markdown for `Site.Build` to render at `/docs`.

  Until 2026-10-15 the Fountain server embedded these pages at compile time
  (`Fountain.Docs`, over the `managoat_docs` hex library) and served them
  itself. The parts of that library the build needs are folded in here as
  plain functions: there is one consumer, so there is no `use` macro and no
  case template (decisions/0081).

  ## The dialect

  The markdown a page may use beyond CommonMark and GFM tables is small, and
  inherited from the MkDocs Material site these pages were published as
  before they moved into the app:

  - `--8<-- "path/to/file"` on a line of its own inlines that file, read
    relative to the repository root (`CHANGELOG.md`, the first request the
    server also serves, an SDK example);
  - `!!! note "Title"` followed by a four-space-indented body becomes a
    blockquote with a bold title line;
  - `[text](other-page.md#anchor)` becomes `/docs/other-page#anchor`,
    resolved against the linking page's own directory.

  Nothing else is rewritten. The site's tests fail if any of the three
  survives preprocessing.

  ## The nav

  `docs/nav.yml` has a `nav:` block that is a hand-written list at most
  three levels deep: the home page and the four Diátaxis categories at the
  top, then a category's sections and pages, then a section's pages.
  `parse_nav/1` reads exactly its two line shapes at three fixed indents and
  **raises** on anything else, a fourth level included: a page silently
  missing from the manual is the bug the parser exists to make impossible.
  """

  @root Path.expand("../../..", __DIR__)
  @mount "/docs"

  @typedoc "`{title, file}`: one page of the nav."
  @type nav_page :: {String.t(), String.t()}

  @typedoc """
  One top-level entry of the nav: a page (the manual's home), or a category
  (`Tutorials`, `How-to guides`, ...) holding pages and sections, each
  section holding pages.
  """
  @type nav_entry ::
          nav_page()
          | {String.t(), [nav_page() | {String.t(), [nav_page()]}]}

  @typedoc "One page: its nav title, its source file under `docs/`, its preprocessed markdown."
  @type page :: %{title: String.t(), file: String.t(), body: String.t()}

  @doc "The repository root: where `docs/` lives and where snippet includes resolve."
  def root, do: @root

  @doc "The directory the pages live in."
  def docs_dir, do: Path.join(@root, "docs")

  @doc "The path the manual is served at."
  def mount, do: @mount

  @doc """
  The whole manual, read from disk: the nav in source shape and every page it
  names, keyed by slug. Read once per VM and kept, because the build and
  every test ask for it.
  """
  @spec load() :: %{nav: [nav_entry()], pages: %{String.t() => page()}}
  def load do
    case :persistent_term.get({__MODULE__, :manual}, nil) do
      nil ->
        manual = read(@root)
        :persistent_term.put({__MODULE__, :manual}, manual)
        manual

      manual ->
        manual
    end
  end

  @doc "Reads the manual under `root` (`docs/nav.yml` and the pages it names)."
  def read(root) do
    docs = Path.join(root, "docs")
    nav = docs |> Path.join("nav.yml") |> File.read!() |> parse_nav()

    pages =
      Map.new(flat_pages(nav), fn {title, file} ->
        body = docs |> Path.join(file) |> File.read!() |> preprocess(file, root)
        {slug_for(file), %{title: title, file: file, body: body}}
      end)

    %{nav: nav, pages: pages}
  end

  @doc "The nav in source shape, `{title, file}`."
  def nav_source, do: load().nav

  @doc """
  The sidebar: `nav_source/0` with each page's file replaced by its slug, so
  `{title, slug}` for a page and `{header, children}` for a category or a
  section.
  """
  def nav, do: slug_tree(nav_source())

  defp slug_tree(entries) do
    Enum.map(entries, fn
      {header, children} when is_list(children) -> {header, slug_tree(children)}
      {title, file} -> {title, slug_for(file)}
    end)
  end

  @doc "Every page slug, in nav order (the home page is `\"\"`)."
  def slugs, do: Enum.map(flat_pages(nav_source()), fn {_title, file} -> slug_for(file) end)

  @doc "A page by slug: `{:ok, page}` or `:error`."
  def get(slug) when is_binary(slug), do: Map.fetch(load().pages, slug)

  @doc "Every file a page includes by snippet, relative to the root, without duplicates."
  def snippet_paths do
    for {_title, file} <- flat_pages(nav_source()),
        [_, path] <- Regex.scan(snippet_pattern(), File.read!(Path.join(docs_dir(), file))),
        uniq: true,
        do: path
  end

  @doc ~S(`"index.md"` → `""`, `"integrations/index.md"` → `"integrations"`, else the rootname.)
  def slug_for(file) do
    case Path.rootname(file) do
      "index" -> ""
      other -> String.replace_suffix(other, "/index", "")
    end
  end

  @doc ~S(`""` → `"/docs"`, `"setup"` → `"/docs/setup"`.)
  def path_for_slug(""), do: @mount
  def path_for_slug(slug), do: @mount <> "/" <> slug

  @doc """
  Parses the `nav:` block of `nav.yml` into the tree described by
  `t:nav_entry/0`, in document order.

  Not a YAML parser, and it does not need to be. What matters is that a line
  it does not recognise raises rather than being skipped, and so does any
  shape the sidebar cannot draw: an indent other than 2, 6 or 10 spaces, a
  header at the third level, a line indented past the entry above it, or a
  category or section with nothing in it.
  """
  @spec parse_nav(String.t()) :: [nav_entry()]
  def parse_nav(yaml) do
    case String.split(yaml, ~r/^nav:\n/m, parts: 2) do
      [_before, block] ->
        {nav, []} = block |> nav_lines() |> Enum.map(&nav_token/1) |> nav_entries(0)
        nav

      _ ->
        raise ArgumentError, "nav.yml has no `nav:` block"
    end
  end

  # The block runs until the first line that is neither blank nor indented,
  # by any whitespace: a tab-indented line must reach `nav_token/1` and
  # raise, not end the block and drop the lines after it. Comments inside it
  # are ignored rather than fatal.
  defp nav_lines(block) do
    block
    |> String.split("\n")
    |> Enum.take_while(&(&1 == "" or String.match?(&1, ~r/^\s/)))
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
  end

  # The three levels sit at fixed indents, so a line's depth is read off its
  # indent and nothing is inferred from its neighbours.
  @nav_depths %{2 => 0, 6 => 1, 10 => 2}

  defp nav_token(line) do
    case Regex.run(~r/^( +)- ([^:]+):[ ]*(\S+)?[ ]*$/, line) do
      [_, indent, title | file] ->
        case Map.fetch(@nav_depths, byte_size(indent)) do
          {:ok, depth} ->
            %{depth: depth, title: title, file: List.first(file), line: line}

          :error when byte_size(indent) > 10 ->
            raise ArgumentError, three_levels_message("nav entry deeper than three levels", line)

          :error ->
            raise ArgumentError,
                  "nav.yml nav line indented #{byte_size(indent)} spaces " <>
                    "(a level is 2, 6 or 10): #{inspect(line)}"
        end

      _ ->
        raise ArgumentError, "unparsed nav.yml nav line: #{inspect(line)}"
    end
  end

  # Reads the entries at `depth` until a shallower line (the parent's next
  # sibling) or the end. A deeper line here has no header above it to belong
  # to, so it raises rather than being promoted.
  defp nav_entries([], _depth), do: {[], []}
  defp nav_entries([%{depth: d} | _] = tokens, depth) when d < depth, do: {[], tokens}

  defp nav_entries([%{depth: d, line: line} | _], depth) when d > depth,
    do: raise(ArgumentError, three_levels_message("nav entry indented past its siblings", line))

  defp nav_entries([token | rest], depth) do
    {entry, rest} = nav_entry(token, rest)
    {more, rest} = nav_entries(rest, depth)
    {[entry | more], rest}
  end

  defp nav_entry(%{title: title, file: file}, rest) when is_binary(file),
    do: {{title, file}, rest}

  defp nav_entry(%{depth: 2, line: line}, _rest),
    do: raise(ArgumentError, three_levels_message("nav section nested in a section", line))

  defp nav_entry(%{depth: depth, title: title, line: line}, rest) do
    case nav_entries(rest, depth + 1) do
      {[], _rest} -> raise ArgumentError, "nav.yml header with nothing under it: #{inspect(line)}"
      {children, rest} -> {{title, children}, rest}
    end
  end

  defp three_levels_message(what, line) do
    """
    #{what}: #{inspect(line)}

    nav.yml is three levels deep at most: a category at 2 spaces, a section
    or page in it at 6, and a section's pages at 10. A section holds pages
    only. Flatten this into a sibling section, or make it headings on a hub
    page.
    """
  end

  @doc "Flattens a nav, at any depth, to `{title, file}` pairs in order."
  def flat_pages(nav) do
    Enum.flat_map(nav, fn
      {_header, children} when is_list(children) -> flat_pages(children)
      {title, file} -> [{title, file}]
    end)
  end

  @doc """
  Snippets, then admonitions, then link rewriting. `file` is the page's path
  relative to `docs/` (links resolve against its directory) and `root` is
  where snippet includes are read from.
  """
  def preprocess(text, file, root) do
    text
    |> expand_snippets(root)
    |> rewrite_admonitions()
    |> rewrite_links(file)
  end

  defp snippet_pattern, do: ~r/^--8<--\s+"([^"]+)"\s*$/m

  @doc false
  def expand_snippets(text, root) do
    Regex.replace(snippet_pattern(), text, fn _, path ->
      root |> Path.join(path) |> File.read!()
    end)
  end

  # `!!! note "Title"` + a 4-space-indented body → a blockquote with a bold
  # title line. Fenced code at the top level is left alone; a fence inside an
  # admonition body arrives indented, so it is consumed as body.
  @doc false
  def rewrite_admonitions(text) do
    text |> String.split("\n") |> admonition_lines(false) |> Enum.join("\n")
  end

  defp admonition_lines([], _in_fence), do: []

  defp admonition_lines([line | rest], in_fence) do
    cond do
      String.starts_with?(line, "```") ->
        [line | admonition_lines(rest, not in_fence)]

      in_fence ->
        [line | admonition_lines(rest, true)]

      match = Regex.run(~r/^!!!\s+(\w+)(?:\s+"([^"]*)")?\s*$/, line) ->
        title =
          case match do
            [_, type] -> String.capitalize(type)
            [_, _type, custom] -> custom
          end

        {body, remaining} = take_indented_body(rest, [])

        quoted =
          Enum.map(body, fn
            "" -> ">"
            content -> "> " <> content
          end)

        ["> **#{title}**", ">"] ++ quoted ++ [""] ++ admonition_lines(remaining, false)

      true ->
        [line | admonition_lines(rest, in_fence)]
    end
  end

  defp take_indented_body([line | rest] = lines, acc) do
    cond do
      String.trim(line) == "" ->
        take_indented_body(rest, ["" | acc])

      String.starts_with?(line, "    ") ->
        take_indented_body(rest, [String.slice(line, 4..-1//1) | acc])

      true ->
        {trim_trailing_blanks(acc), lines}
    end
  end

  defp take_indented_body([], acc), do: {trim_trailing_blanks(acc), []}

  defp trim_trailing_blanks(reversed_acc),
    do: reversed_acc |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

  # `[x](setup.md#backups)` → `[x](/docs/setup#backups)`, resolved against the
  # page's own directory so `../architecture.md` works from integrations/.
  @doc false
  def rewrite_links(text, file) do
    dir = Path.dirname(file)

    Regex.replace(~r/\]\((?!https?:)([^)\s#]+\.md)(#[^)]*)?\)/, text, fn _, target, anchor ->
      slug = target |> Path.expand("/" <> dir) |> String.trim_leading("/") |> slug_for()
      "](#{path_for_slug(slug)}#{anchor})"
    end)
  end

  @doc """
  The search index: one entry per page, in nav order, with the `<h2>`–`<h6>`
  headings of its **rendered** HTML. A heading's `id` is the one comrak gave
  it on that page, so a result deep-links to an anchor that exists; no second
  slugging pass is allowed to drift from it.
  """
  def search_index(rendered) do
    for slug <- slugs() do
      {:ok, %{title: title}} = get(slug)
      %{title: title, slug: slug, headings: extract_headings(Map.fetch!(rendered, slug))}
    end
  end

  @doc """
  `{id, text}` for every `<h2>`–`<h6>` in rendered HTML, in document order.
  `<h1>` is skipped: every page has one, and it repeats the nav title a
  search result already shows.
  """
  def extract_headings(html) do
    ~r/<h[2-6]([^>]*)>(.*?)<\/h[2-6]>/s
    |> Regex.scan(html)
    |> Enum.map(fn [_, attrs, inner] -> %{id: heading_id(attrs), text: heading_text(inner)} end)
    |> Enum.reject(&(&1.id == nil or &1.text == ""))
  end

  defp heading_id(attrs) do
    case Regex.run(~r/\sid="([^"]*)"/, attrs) do
      [_, id] -> id
      nil -> nil
    end
  end

  # Strips inner markup (`## \`fountain apply\`` renders `<code>` inside the
  # heading) and decodes the entities comrak emits in text. `&amp;` goes last:
  # a heading holding a literal `&lt;` renders as `&amp;lt;`, and decoding the
  # ampersand first would turn it into `<`.
  defp heading_text(inner) do
    inner
    |> String.replace(~r/<[^>]*>/s, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.trim()
  end
end
