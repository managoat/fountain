defmodule Managoat.Runtimes.Skills.Discovery do
  @moduledoc """
  Which directories of a fetched GitHub repository are skills, and which of
  them an agent's skill entry selects.

  These are the rules of the skills.sh CLI (`discoverSkills` and
  `filterSkills` in vercel-labs/skills `src/skills.ts`, and `sanitizeName`
  in `src/installer.ts`), which installed GitHub skills before Managoat
  fetched them itself, so an agent selects the same skills it always did:

    * A `SKILL.md` at the search root is the one skill, and the search stops.
    * Otherwise the root's children are tried, then `skills/`,
      `skills/.curated`, `.experimental` and `.system`, then each agent's
      project skills directory (`.claude/skills` and the rest). Those
      containers are walked three levels deep; the root one level. A
      directory with a `SKILL.md` is a skill and is not descended into.
    * Then the directories named by `.claude-plugin/marketplace.json` and
      `plugin.json`, one level deep (three when one is also a container
      above).
    * Only when all of that found nothing, every directory with a `SKILL.md`
      up to five levels down.

  A `SKILL.md` counts when its YAML frontmatter has a string `name` and
  `description`. One whose `metadata.internal` is true is left out unless it
  is asked for by name. The first skill with a given name wins. A skill is
  installed under its name in kebab case (`sanitize_name/1`).

  The input is what the fetch printed rather than a filesystem: every
  `SKILL.md`'s directory relative to the repository root (`""` for the root
  itself) and its contents, and the plugin manifests by path. Within a
  directory, entries are taken in name order; skills.sh takes them in the
  filesystem's order, which only matters when two skills share a name.

  Not carried over: skills.sh's `--full-depth`, and its skipping of a skill a
  repository's own `skills-lock.json` says it installed into an agent
  directory. The frontmatter reader is not a YAML parser: it reads top-level
  scalars (plain, quoted, folded or literal) and `metadata.internal`, which
  is all that discovery needs.
  """

  @skip_dirs ~w(node_modules .git dist build __pycache__)

  @agent_project_skill_dirs ~w(
    .agents/skills .claude/skills .cline/skills .codebuddy/skills .codex/skills
    .commandcode/skills .continue/skills .factory/skills .github/skills
    .goose/skills .grok/skills .iflow/skills .junie/skills .kilo/skills
    .kilocode/skills .kimchi/skills .kiro/skills .minimax/skills .mux/skills
    .neovate/skills .opencode/skills .openhands/skills .pi/skills
    .posit/assistant/skills .qoder/skills .roo/skills .trae/skills
    .windsurf/skills .zcode/skills .zencoder/skills
  )

  @container_depth 3
  @fallback_depth 5

  @typedoc "A discovered skill: its frontmatter name and its directory in the repository."
  @type skill :: %{name: String.t(), dir: String.t()}

  @doc """
  The skills under `subpath` (`nil` or `""` for the repository root), in
  discovery order.

  `skill_files` maps each directory holding a `SKILL.md` to that file's
  contents; `manifests` maps a `.claude-plugin/*.json` path to its contents.
  With `include_internal: true` a skill marked internal counts too, which is
  what a request by name does.
  """
  @spec discover(%{String.t() => String.t()}, %{String.t() => String.t()}, String.t() | nil,
          include_internal: boolean()
        ) :: [skill()]
  def discover(skill_files, manifests, subpath, opts \\ []) do
    include_internal = Keyword.get(opts, :include_internal, false)
    search = normalize(subpath || "") || ""
    parse = fn dir -> parse(Map.fetch!(skill_files, dir), include_internal) end
    dirs = skill_files |> Map.keys() |> Enum.sort_by(&segments/1)

    root_skill = if Map.has_key?(skill_files, search), do: parse.(search)

    if root_skill do
      [%{name: root_skill, dir: search}]
    else
      found = walk_containers(search, dirs, manifests, parse)
      if found == [], do: fallback(search, dirs, parse), else: found
    end
  end

  @doc """
  The skills an entry selects: all of them for no name, otherwise the ones
  whose name matches it, ignoring case.
  """
  @spec select([skill()], String.t() | nil) :: [skill()]
  def select(skills, name) when name in [nil, ""], do: skills

  def select(skills, name) do
    wanted = String.downcase(name)
    Enum.filter(skills, &(String.downcase(&1.name) == wanted))
  end

  @doc """
  The directory name a skill is installed under: lower case, every run of
  characters other than `a-z0-9._` one hyphen, no leading or trailing dot or
  hyphen. skills.sh's `sanitizeName`.
  """
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) do
    sanitized =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._]+/, "-")
      |> String.replace(~r/^[.\-]+|[.\-]+$/, "")
      |> binary_slice(0, 255)

    if sanitized == "", do: "unnamed-skill", else: sanitized
  end

  # -- the priority walk ------------------------------------------------------

  defp walk_containers(search, dirs, manifests, parse) do
    deep = Enum.map(priority_dirs(search) -- [search], &{&1, @container_depth})
    containers = [{search, 1} | deep] ++ plugin_dirs(search, manifests, MapSet.new(deep))
    dir_set = MapSet.new(dirs)

    {found, _seen, _visited} =
      Enum.reduce(containers, {[], MapSet.new(), MapSet.new()}, fn {container, depth}, acc ->
        dirs
        |> Enum.filter(&reachable?(&1, container, depth, dir_set))
        |> Enum.reduce(acc, &add(&1, &2, parse))
      end)

    Enum.reverse(found)
  end

  defp priority_dirs(search) do
    [
      search
      | Enum.map(
          ["skills", "skills/.curated", "skills/.experimental", "skills/.system"],
          &join(search, &1)
        )
    ] ++
      Enum.map(@agent_project_skill_dirs, &join(search, &1))
  end

  # A walk from `container` reaches `dir` when it lies 1..depth levels below,
  # through no skipped directory and no directory that is itself a skill
  # (the walk does not descend into one).
  defp reachable?(dir, container, depth, dir_set) do
    case relative(dir, container) do
      {:ok, rel} when rel != [] and length(rel) <= depth ->
        between = Enum.drop(rel, -1)

        Enum.all?(between, &(&1 not in @skip_dirs)) and
          not Enum.any?(1..length(between)//1, fn n ->
            MapSet.member?(dir_set, join(container, Enum.join(Enum.take(rel, n), "/")))
          end)

      _ ->
        false
    end
  end

  # Each SKILL.md is read once, whichever container reaches it first.
  defp add(dir, {found, seen, visited}, parse) do
    if MapSet.member?(visited, dir) do
      {found, seen, visited}
    else
      visited = MapSet.put(visited, dir)

      case parse.(dir) do
        nil ->
          {found, seen, visited}

        name ->
          if name in seen,
            do: {found, seen, visited},
            else: {[%{name: name, dir: dir} | found], MapSet.put(seen, name), visited}
      end
    end
  end

  defp fallback(search, dirs, parse) do
    {found, _seen} =
      dirs
      |> Enum.filter(fn dir ->
        case relative(dir, search) do
          {:ok, rel} -> length(rel) <= @fallback_depth and Enum.all?(rel, &(&1 not in @skip_dirs))
          :error -> false
        end
      end)
      |> Enum.reduce({[], MapSet.new()}, fn dir, {found, seen} ->
        case parse.(dir) do
          nil ->
            {found, seen}

          name ->
            if name in seen,
              do: {found, seen},
              else: {[%{name: name, dir: dir} | found], MapSet.put(seen, name)}
        end
      end)

    Enum.reverse(found)
  end

  # -- plugin manifests -------------------------------------------------------

  # The containers `.claude-plugin/marketplace.json` (each local plugin's
  # listed skills' parent directories and its `skills/`) and `plugin.json`
  # name, kept inside the search root. skills.sh's `getPluginSkillPaths`.
  defp plugin_dirs(search, manifests, deep) do
    marketplace =
      case decode(manifests, join(search, ".claude-plugin/marketplace.json")) do
        %{"plugins" => plugins} = manifest when is_list(plugins) ->
          plugin_root = get_in(manifest, ["metadata", "pluginRoot"])

          if is_nil(plugin_root) or dot_relative?(plugin_root) do
            Enum.flat_map(plugins, fn
              %{} = plugin ->
                source = plugin["source"]

                cond do
                  not (is_nil(source) or (is_binary(source) and dot_relative?(source))) ->
                    []

                  true ->
                    plugin_paths(
                      search,
                      join(join(search, plugin_root || ""), source || ""),
                      plugin["skills"]
                    )
                end

              _ ->
                []
            end)
          else
            []
          end

        _ ->
          []
      end

    plugin =
      case decode(manifests, join(search, ".claude-plugin/plugin.json")) do
        %{} = manifest -> plugin_paths(search, search, manifest["skills"])
        _ -> []
      end

    Enum.map(marketplace ++ plugin, fn dir ->
      {dir, if(MapSet.member?(deep, {dir, @container_depth}), do: @container_depth, else: 1)}
    end)
  end

  defp plugin_paths(search, base, skills) do
    with base when is_binary(base) <- normalize(base),
         {:ok, _} <- relative(base, search) do
      listed =
        for path <- List.wrap(skills),
            is_binary(path) and dot_relative?(path),
            dir = normalize(Path.dirname(join(base, path))),
            is_binary(dir),
            match?({:ok, _}, relative(dir, search)),
            do: dir

      listed ++ [join(base, "skills")]
    else
      _ -> []
    end
  end

  defp decode(manifests, path) do
    with raw when is_binary(raw) <- Map.get(manifests, path),
         {:ok, %{} = map} <- Jason.decode(raw) do
      map
    else
      _ -> nil
    end
  end

  defp dot_relative?(path), do: is_binary(path) and String.starts_with?(path, "./")

  # -- paths ------------------------------------------------------------------

  defp segments(""), do: []
  defp segments(path), do: String.split(path, "/")

  defp join("", path), do: normalize(path) || path
  defp join(base, ""), do: base
  defp join(base, path), do: normalize(base <> "/" <> path) || base <> "/" <> path

  # Resolves `.` and `..`; nil for a path that climbs out of the repository.
  defp normalize(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce_while([], fn
      ".", acc -> {:cont, acc}
      "..", [] -> {:halt, :escaped}
      "..", [_ | acc] -> {:cont, acc}
      segment, acc -> {:cont, [segment | acc]}
    end)
    |> case do
      :escaped -> nil
      acc -> acc |> Enum.reverse() |> Enum.join("/")
    end
  end

  defp relative(dir, ""), do: {:ok, segments(dir)}
  defp relative(dir, dir), do: {:ok, []}

  defp relative(dir, base) do
    if String.starts_with?(dir, base <> "/"),
      do:
        {:ok,
         segments(binary_part(dir, byte_size(base) + 1, byte_size(dir) - byte_size(base) - 1))},
      else: :error
  end

  # -- frontmatter ------------------------------------------------------------

  @doc """
  The skill name a `SKILL.md` declares, or nil when it does not count: no
  frontmatter, no string `name` or `description`, or `metadata.internal`
  without `include_internal`. The name has control characters and line
  breaks removed, as skills.sh's `sanitizeMetadata` does.
  """
  @spec parse(String.t(), boolean()) :: String.t() | nil
  def parse(content, include_internal \\ false) do
    with %{} = fields <- frontmatter(content),
         {:string, name} <- Map.get(fields, "name"),
         {:string, description} <- Map.get(fields, "description"),
         name = clean(name),
         true <- name != "" and clean(description) != "",
         false <- Map.get(fields, :internal, false) and not include_internal do
      name
    else
      _ -> nil
    end
  end

  defp frontmatter(content) do
    case Regex.run(~r/\A\x{FEFF}?---\r?\n(.*?)\r?\n---/su, content) do
      [_, block] -> block |> String.split(~r/\r?\n/) |> fields(%{})
      _ -> nil
    end
  end

  defp fields([], acc), do: acc

  defp fields([line | rest], acc) do
    case Regex.run(~r/\A([^\s#][^:]*?):(?:\s+(.*?))?\s*\z/u, line) do
      [_ | captures] ->
        [key | value] = captures
        {block, rest} = Enum.split_while(rest, &continuation?/1)
        fields(rest, put_field(acc, key, List.first(value) || "", block))

      nil ->
        fields(rest, acc)
    end
  end

  defp continuation?(line), do: line == "" or String.starts_with?(line, [" ", "\t"])

  defp put_field(acc, "metadata", "", block) do
    internal =
      Enum.any?(block, &Regex.match?(~r/\A\s+internal:\s*true\s*(#.*)?\z/, &1))

    Map.put(acc, :internal, internal)
  end

  defp put_field(acc, key, value, block), do: Map.put(acc, key, scalar(value, block))

  # A block scalar (`|`, `>`) or a plain/quoted scalar continued on indented
  # lines. Plain `true`, `42`, `null` and the like are not strings to YAML.
  defp scalar(value, block) do
    rest = block |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      Regex.match?(~r/\A[|>][-+0-9]*\z/, value) ->
        {:string, Enum.join(rest, " ")}

      value == "" and rest != [] and
          Enum.all?(rest, &Regex.match?(~r/\A(- |[^\s:]+:(\s|\z))/, &1)) ->
        :collection

      String.starts_with?(value, ["\"", "'"]) ->
        {:string, unquote_scalar(Enum.join([value | rest], " "))}

      true ->
        text =
          [value | rest] |> Enum.join(" ") |> String.replace(~r/\s+#.*\z/, "") |> String.trim()

        if text == "" or
             Regex.match?(
               ~r/\A(true|false|yes|no|null|~|[-+]?(\d[\d_]*)?(\.\d+)?([eE][-+]?\d+)?)\z/i,
               text
             ),
           do: :scalar,
           else: {:string, text}
    end
  end

  defp unquote_scalar("\"" <> rest) do
    rest
    |> String.replace(~r/"\s*(#.*)?\z/, "")
    |> String.replace(~S(\"), "\"")
    |> String.replace(~S(\\), "\\")
  end

  defp unquote_scalar("'" <> rest),
    do: rest |> String.replace(~r/'\s*(#.*)?\z/, "") |> String.replace("''", "'")

  defp clean(text) do
    text
    |> String.replace(
      ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a\e]*(\a|\e\\)|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/u,
      ""
    )
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
  end
end
