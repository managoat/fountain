defmodule Fountain.SandboxSkills do
  @moduledoc """
  The skills every Fountain sandbox gets, and the call that mounts them with
  the agent's own.

  The mechanism — inline `SKILL.md` writes under the runtime's skills root,
  skills.sh installs for github sources, the shell allow-list — is
  `Managoat.Runtimes.Skills`. What is Fountain's is the content: the bundled
  skills under `priv/sprite_skills/`, prepended to every agent's list so the
  per-conversation callback API and the team set-up Q&A are discoverable
  inside the sprite.
  """

  require Logger

  @bundle_root "sprite_skills"
  # Written at the skills root: which directories each Fountain-managed skill
  # put there, so a later reconciliation knows what it owns.
  @manifest_name ".fountain-managed-skills"
  @fountain_skill_name "fountain"
  # Every sandbox gets these, in this order: the API skill, then the team
  # set-up Q&A (#851) — so a first teammate can answer "/create-team".
  @bundled_skills [@fountain_skill_name, "create-team"]

  @doc """
  Mount `skills` (a list of inline/github maps, the agent's `skills` field)
  on the sandbox behind `handle` for the named runtime. The bundled skills
  are always prepended.

  A runtime **string** is resolved here, through `Fountain.RuntimeDispatch`
  rather than through the library's own dispatcher (#1634).
  `Managoat.Runtimes.Skills` resolves a string through
  `Managoat.Runtimes.for_runtime/1`, which is a closed map of the four
  packaged runtimes and knows neither `acp` nor the deployed fixture — so
  passing the string straight through returned
  `{:error, "unsupported runtime: acp"}` and an acp sandbox came up with no
  skills at all and nothing said so.

  Failure is logged rather than raised, and returned for a caller that wants
  it. A missing skill is a degraded agent, not a broken one, which is the
  trade `Managoat.Runtimes.Skills` already makes for one skill that will not
  install; this extends it to a runtime that cannot be resolved.
  """
  @spec mount(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil) ::
          :ok | {:error, String.t()}
  def mount(handle, runtime, skills) when is_binary(runtime) do
    # `for_agent/1` takes the agent because the deployed fixture is scoped to
    # one account. Skills are refused on a fixture agent by its own changeset,
    # so a nil user here resolves to the refusal, which is the right answer.
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        mount(handle, module, skills)

      {:error, reason} ->
        Logger.warning("skills not mounted for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def mount(handle, runtime_module, skills) when is_atom(runtime_module) do
    reconcile(handle, runtime_module, skills, [])
  end

  @doc """
  `mount/3` for a machine this provision has just created.

  A fresh machine has no manifest and nothing to remove, so reconciling it
  only reads an absent manifest, `mkdir`s the root and rewrites the manifest
  before each skill: 2 execs and 6 writes for the bundled skills, ~0.85 s on
  a sprite (measured 2026-09-26). When every selected skill is inline, this
  writes the manifest reconciliation would end with, then the skills, under
  the same lock: no execs, one write per file. The manifest still goes
  first, so a failure part-way leaves files it owns rather than files nobody
  owns. A
  remote skill names its own directories, which only a real reconcile
  discovers, so any remote skill falls back to `mount/3`.

  Only for a machine nothing else has written skills to: a reapply or a
  reattach reconciles.
  """
  @spec mount_fresh(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil) ::
          :ok | {:error, term()}
  def mount_fresh(handle, runtime, skills) when is_binary(runtime) do
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        mount_fresh(handle, module, skills)

      {:error, reason} ->
        Logger.warning("skills not mounted for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def mount_fresh(handle, runtime_module, skills) when is_atom(runtime_module) do
    selected = normalize(bundled() ++ (skills || []))

    if Enum.all?(selected, &is_binary(&1["content"])) do
      root = runtime_module.skills_root()

      with_skill_lock(handle, root, fn ->
        with :ok <-
               write_manifest(handle, Path.join(root, @manifest_name), named_manifest(selected)) do
          Managoat.Runtimes.Skills.install(handle, selected, runtime: runtime_module)
        end
      end)
    else
      mount(handle, runtime_module, skills)
    end
  end

  @doc """
  Replace the Fountain-managed skills on a machine, leaving everything else
  under the skills root alone (#1565).

  Installing is not enough once a conversation can be reapplied. A skill the
  agent no longer names is still on the disk, and the runtime still reads it,
  so removing one from an agent would change nothing until the machine was
  rebuilt. Reconciling deletes what Fountain put there and is no longer
  selected, and only that.

  Ownership comes from these records:

  - **A manifest, written at the skills root.** It maps each selected skill
    to the directory names its install produced, so a later pass knows what
    it owns. A GitHub install without a `--skill` name decides its own
    directory names, which is why the manifest records what appeared rather
    than what was asked for.
  - **`previous`, used only when the manifest is absent.** The
    conversation's recorded Agent version names the skills that were
    installed, and the skills.sh source lock names the directories an unnamed
    GitHub install produced. Recovery is persisted before any skill changes.
    A present manifest is authoritative; historical names are never merged
    back into it. Anything neither can account for is left where
    it is: an entry with no ownership record is somebody else's.
  - **An install in progress.** Before a GitHub install starts, the manifest
    records its source and the names already on disk. Each install commits
    its discovered names before the next one starts. Automatic retries refuse
    pending installs: remote execution may outlive its caller. An explicit
    upgrade on a quiesced sandbox recovers new names from new source-lock
    evidence; ambiguous or missing evidence stops the upgrade.
  - **Only direct children of the skills root are ever removed**, each one
    matched against a conservative name pattern. Neither a forged manifest
    nor a legacy skill name can turn reconciliation into a delete somewhere
    else on the disk.

  A remote skill that is still selected keeps its directory when its
  reinstall fails, which is what an offline machine under a restrictive
  network policy looks like: the copy on the disk is the working one.
  """
  @spec reconcile(
          Managoat.Sandbox.Handle.t(),
          String.t() | module(),
          [map()] | nil,
          [map()] | nil
        ) ::
          :ok | {:error, term()}
  def reconcile(handle, runtime, skills, previous) when is_binary(runtime) do
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        reconcile(handle, module, skills, previous)

      {:error, reason} ->
        Logger.warning("skills not reconciled for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def reconcile(handle, runtime_module, skills, previous) when is_atom(runtime_module) do
    root = runtime_module.skills_root()

    with_skill_lock(handle, root, fn ->
      do_reconcile(handle, runtime_module, root, skills, previous)
    end)
  end

  defp do_reconcile(handle, runtime_module, root, skills, previous) do
    manifest = Path.join(root, @manifest_name)
    selected = bundled() ++ (skills || [])

    with {:ok, managed} <- ensure_manifest(handle, manifest, previous),
         obsolete = obsolete_names(managed, selected),
         {:ok, _} <- run(handle, remove(root, obsolete)),
         {:ok, installed} <- install_selected(handle, runtime_module, root, selected, managed) do
      write_manifest(handle, manifest, installed)
    end
  end

  @doc """
  Inspect the ownership manifest using an already-owned sandbox handle.

  Returns `:missing`, `:present`, `:pending` or `:invalid`, never skill contents.
  This performs provider I/O and can wake a sleeping disk. It does not install,
  delete or write anything, and says nothing about build fingerprints.
  """
  @spec manifest_status(Managoat.Sandbox.Handle.t(), String.t() | module()) ::
          {:ok, :missing | :present | :pending | :invalid} | {:error, term()}
  def manifest_status(handle, runtime) do
    with {:ok, module} <- runtime_module(runtime) do
      case read_manifest(handle, Path.join(module.skills_root(), @manifest_name)) do
        {:ok, nil} -> {:ok, :missing}
        {:ok, {:pending, _, _}} -> {:ok, :pending}
        {:ok, _managed} -> {:ok, :present}
        {:error, :invalid_skill_manifest} -> {:ok, :invalid}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Adopt legacy skill ownership once, without changing any installed skills.

  `previous` must be the recorded applied selection or the conversation's
  historical Agent version, never the agent's current mutable configuration.
  Names and matching GitHub source-lock entries seed an absent manifest.
  Completed valid manifests are left byte-for-byte unchanged; invalid manifests
  are refused. An interrupted install recovers only its recorded source and
  newly created names before committing ownership. A completed reconciliation
  cannot reclaim names that Fountain has since removed. This is an operator
  command: quiesce the machine and stop any surviving remote installers before
  recovering a pending install. A caller dying does not stop remote execution.
  """
  @spec upgrade_manifest(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil) ::
          :ok | {:error, term()}
  def upgrade_manifest(handle, runtime, previous) do
    with {:ok, module} <- runtime_module(runtime) do
      root = module.skills_root()

      with_skill_lock(handle, root, fn ->
        with {:ok, _} <- ensure_manifest(handle, Path.join(root, @manifest_name), previous, true),
             do: :ok
      end)
    end
  end

  # Conversation processes can share a sandbox. Use the sandbox identity across
  # connected nodes, not the conversation, and refuse competing mutations.
  defp with_skill_lock(handle, root, fun) do
    lock = {{__MODULE__, handle.provider, handle.name, root}, self()}
    nodes = [node() | Node.list()]

    if :global.set_lock(lock, nodes, 0) do
      try do
        fun.()
      after
        :global.del_lock(lock, nodes)
      end
    else
      {:error, :skill_reconciliation_busy}
    end
  end

  defp runtime_module(runtime) when is_atom(runtime), do: {:ok, runtime}

  defp runtime_module(runtime),
    do: Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil})

  defp ensure_manifest(handle, manifest, previous, recover_pending \\ false) do
    case read_manifest(handle, manifest) do
      {:ok, nil} ->
        with {:ok, recovered} <- legacy_manifest(handle, previous),
             :ok <- write_manifest(handle, manifest, recovered) do
          {:ok, recovered}
        end

      {:ok, {:pending, managed, pending}} when recover_pending ->
        recover_install(handle, manifest, managed, pending)

      {:ok, {:pending, _, _}} ->
        {:error, :skill_installation_incomplete}

      result ->
        result
    end
  end

  defp recover_install(handle, manifest, managed, pending) do
    with {:ok, current} <- run(handle, listing(Path.dirname(manifest))),
         added = entries(current) -- pending["before"],
         {:ok, recovered} <- interrupted_names(handle, pending, added),
         key = identity(pending),
         next = Map.put(managed, key, Enum.uniq(recovered ++ Map.get(managed, key, []))),
         :ok <- write_manifest(handle, manifest, next) do
      {:ok, next}
    end
  end

  defp interrupted_names(_handle, %{"name" => name}, _added) when is_binary(name),
    do: {:ok, [name]}

  # No new names means execution never started, or only rewrote existing files.
  # Otherwise the recorded source's lock entries must identify the new names:
  # do not adopt arbitrary files created while the sandbox was unattended.
  defp interrupted_names(_handle, _pending, []), do: {:ok, []}

  defp interrupted_names(handle, pending, added) do
    with {:ok, recovered} <- legacy_manifest(handle, [pending]),
         names = Enum.filter(Map.fetch!(recovered, identity(pending)), &(&1 in added)),
         false <- names == [] or Enum.any?(names, &(&1 in pending["locked_before"])) do
      {:ok, names}
    else
      {:error, :legacy_skill_ownership_unknown} -> {:error, :skill_installation_incomplete}
      true -> {:error, :skill_installation_incomplete}
      {:error, _} = error -> error
    end
  end

  defp write_manifest(handle, path, state),
    do: Managoat.Sandbox.write_file(handle, path, Jason.encode!(state))

  defp read_manifest(handle, manifest) do
    # The newline distinguishes an empty (invalid) file from an absent file.
    # Reject symlinks and non-files rather than following them outside root.
    script = """
    if [ -L #{quote_shell(manifest)} ]; then
      printf 'invalid'
    elif [ -f #{quote_shell(manifest)} ]; then
      cat -- #{quote_shell(manifest)} || exit
      printf '\n'
    elif [ -e #{quote_shell(manifest)} ]; then
      printf 'invalid'
    fi
    """

    with {:ok, raw} <- run(handle, script), do: decode_manifest(raw)
  end

  # Stable across content and ref edits: a retained remote skill stays usable
  # when its best-effort reinstall is refused by the network policy.
  defp identity(skill), do: Jason.encode!([skill["source"], skill["name"]])

  defp normalize(skills),
    do: Enum.map(skills || [], fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end)

  defp named_manifest(skills),
    do: Map.new(normalize(skills), fn s -> {identity(s), names(s)} end)

  # skills.sh records globally installed names by source, including installs
  # made without --skill. Recover those on disks predating Fountain's own
  # manifest. Format: https://github.com/vercel-labs/skills/blob/main/src/skill-lock.ts
  defp legacy_manifest(_handle, nil), do: {:error, :legacy_skill_ownership_unknown}

  defp legacy_manifest(handle, previous) do
    unnamed = Enum.filter(normalize(previous), &(is_binary(&1["source"]) and is_nil(&1["name"])))

    if unnamed == [] do
      {:ok, named_manifest(previous)}
    else
      with {:ok, locked} <- source_lock(handle) do
        recovered =
          Map.new(unnamed, fn entry ->
            names =
              Enum.flat_map(locked, fn
                {name, %{"source" => source, "sourceType" => "github"}} ->
                  if source == entry["source"] and safe_name?(name), do: [name], else: []

                _ ->
                  []
              end)

            {identity(entry), names}
          end)

        if Enum.any?(recovered, fn {_identity, names} -> names == [] end) do
          {:error, :legacy_skill_ownership_unknown}
        else
          {:ok, Map.merge(named_manifest(previous), recovered)}
        end
      end
    end
  end

  defp source_lock(handle, strict \\ false) do
    script = ~S"""
    if [ -n "${XDG_STATE_HOME:-}" ]; then
      skills_lock="$XDG_STATE_HOME/skills/.skill-lock.json"
    else
      skills_lock="$HOME/.agents/.skill-lock.json"
    fi
    if [ -f "$skills_lock" ]; then cat -- "$skills_lock"; fi
    """

    with {:ok, raw} <- run(handle, script) do
      case Jason.decode(raw) do
        {:ok, %{"skills" => skills}} when is_map(skills) -> {:ok, skills}
        _ when raw == "" or not strict -> {:ok, %{}}
        _ -> {:error, :skill_installation_incomplete}
      end
    end
  end

  defp locked_names_before(_handle, %{"name" => name}) when is_binary(name), do: {:ok, []}

  defp locked_names_before(handle, skill) do
    with {:ok, locked} <- source_lock(handle, true) do
      {:ok,
       Enum.flat_map(locked, fn
         {name, %{"source" => source, "sourceType" => "github"}} ->
           if source == skill["source"] and safe_name?(name), do: [name], else: []

         _ ->
           []
       end)}
    end
  end

  defp decode_manifest(""), do: {:ok, nil}

  defp decode_manifest(raw) do
    case Jason.decode(raw) do
      {:ok, %{"version" => 1, "managed" => managed, "installing" => pending}} ->
        if valid_managed?(managed) and valid_pending?(pending),
          do: {:ok, {:pending, managed, pending}},
          else: {:error, :invalid_skill_manifest}

      {:ok, map} when is_map(map) ->
        if valid_managed?(map) do
          {:ok, map}
        else
          {:error, :invalid_skill_manifest}
        end

      _ ->
        {:error, :invalid_skill_manifest}
    end
  end

  defp valid_managed?(map) when is_map(map),
    do: Enum.all?(map, fn {_key, values} -> valid_names?(values) end)

  defp valid_managed?(_), do: false

  defp valid_pending?(%{
         "source" => source,
         "name" => name,
         "before" => before,
         "locked_before" => locked
       }),
       do:
         is_binary(source) and source != "" and (is_nil(name) or safe_name?(name)) and
           valid_names?(before) and valid_names?(locked)

  defp valid_pending?(_), do: false
  defp valid_names?(values), do: is_list(values) and Enum.all?(values, &safe_name?/1)

  # A name is obsolete when it belonged to a skill that is no longer selected
  # and no selected skill claims it. Two skills can produce the same directory
  # name, so a retained claim always wins over a dropped one.
  defp obsolete_names(managed, selected) do
    wanted = named_manifest(selected)
    retained = managed |> Map.take(Map.keys(wanted)) |> Map.values() |> List.flatten()
    removed = managed |> Map.drop(Map.keys(wanted)) |> Map.values() |> List.flatten()
    Enum.uniq(removed -- (retained ++ (wanted |> Map.values() |> List.flatten())))
  end

  defp install_selected(handle, runtime, root, selected, managed) do
    {inline, remote} = Enum.split_with(normalize(selected), &is_binary(&1["content"]))

    # GitHub installs first, as in the library: their blocking exec is also the
    # readiness barrier before the sandbox accepts inline file writes.
    result =
      Enum.reduce_while(remote ++ inline, {:ok, managed}, fn skill, {:ok, installed} ->
        case install_skill(handle, runtime, root, skill, installed) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, installed} <- result,
         do: {:ok, Map.take(installed, Enum.map(normalize(selected), &identity/1))}
  end

  defp install_skill(handle, runtime, root, %{"content" => _} = skill, managed) do
    next = Map.put(managed, identity(skill), names(skill))

    # Inline installs have an explicit destination: record it before writing.
    with :ok <- write_manifest(handle, Path.join(root, @manifest_name), next),
         :ok <- Managoat.Runtimes.Skills.install(handle, [skill], runtime: runtime),
         do: {:ok, next}
  end

  # A remote install names its own directories, so they are read off the disk
  # rather than assumed. The names already recorded for this skill are kept
  # too, so a reinstall the network refused does not make the copy on disk
  # look unowned and get deleted on the next pass.
  defp install_skill(handle, runtime, root, skill, managed) do
    manifest = Path.join(root, @manifest_name)

    with {:ok, before} <- run(handle, listing(root)),
         {:ok, locked} <- locked_names_before(handle, skill),
         pending = %{
           "source" => skill["source"],
           "name" => skill["name"],
           "before" => entries(before),
           "locked_before" => locked
         },
         :ok <-
           write_manifest(handle, manifest, %{
             "version" => 1,
             "managed" => managed,
             "installing" => pending
           }),
         :ok <- Managoat.Runtimes.Skills.install(handle, [skill], runtime: runtime),
         {:ok, after_install} <- run(handle, listing(root)),
         owned =
           Enum.uniq(
             (entries(after_install) -- entries(before)) ++
               names(skill) ++ Map.get(managed, identity(skill), [])
           ),
         next = Map.put(managed, identity(skill), owned),
         :ok <- write_manifest(handle, manifest, next) do
      {:ok, next}
    end
  end

  defp names(skill), do: if(safe_name?(skill["name"]), do: [skill["name"]], else: [])

  defp safe_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name)

  defp safe_name?(_), do: false
  defp entries(text), do: text |> String.split("\n", trim: true) |> Enum.filter(&safe_name?/1)

  defp remove(root, names) do
    "mkdir -p -- #{quote_shell(root)}\n" <>
      Enum.map_join(names, "\n", fn name -> "rm -rf -- #{quote_shell(Path.join(root, name))}" end)
  end

  defp listing(root) do
    """
    for path in #{quote_shell(root)}/*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      basename -- "$path"
    done
    """
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp run(handle, script) do
    case Managoat.Sandbox.exec(handle, "bash", ["-c", script], stderr_to_stdout: true) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, code} -> {:error, "skill reconciliation exited with #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The bundled skills as inline entries, in the order they are mounted.
  """
  @spec bundled() :: [%{String.t() => String.t()}]
  # sobelow_skip ["Traversal.FileModule"] — fixed path assembled from
  # priv_dir and a module attribute; no user input.
  def bundled do
    Enum.map(@bundled_skills, fn name ->
      %{"name" => name, "content" => File.read!(Path.join([priv_dir(), name, "SKILL.md"]))}
    end)
  end

  defp priv_dir do
    Path.join(:code.priv_dir(:fountain) |> to_string(), @bundle_root)
  end
end
