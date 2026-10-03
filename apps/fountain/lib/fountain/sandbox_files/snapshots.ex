defmodule Fountain.SandboxFiles.Snapshots do
  @moduledoc """
  What a parked sandbox's files API answers from (ADR 0063).

  A parked machine is not woken for a read (ADR 0039 decision 6), so until
  this module an app watching an agent showed nothing at all once the machine
  went to sleep — exactly when somebody comes back to look at what it did. So
  the park takes a picture first: `capture/1` runs inside
  `Fountain.Machines.Park`, under the park's lease and its `parking` stamp,
  after the checkpoint and before the suspend, while the machine is still up
  and nobody can be working on it. `Fountain.SandboxFiles` answers a read of
  a `suspended` sandbox from that picture where it can, with `snapshot_at`
  saying how old it is, and with the `409 sandbox_not_ready` it always gave
  where it cannot.

  ## What is kept

  The git work trees under the runtime's working directory, because that is
  where an agent's work is and because git already knows which files are
  worth looking at: `git ls-files -co --exclude-standard`, tracked plus
  untracked-but-not-ignored, so `node_modules`, build output and the dotfiles
  in the home are left out without a list of names to keep current. For each
  repository, the default `git diff` and `git status` (in its `all` and
  `normal` forms; `no` is `all` filtered). Then the listing of every directory
  those files sit in, and of the directories between the working directory
  and each repository, so that a client can walk down to them. Then the bytes
  of the files themselves, changed ones first and then the shallowest, up to
  the bounds below.

  Anything outside that — an ignored directory, a file past a bound, a diff
  against a ref, a path through a symlink — is not in the picture, and a read
  of it is refused as before. A picture that cannot say is never a guess.

  ## Bounds

  16 repositories, 20,000 paths and 1,500 directories surveyed; files up to
  256 KiB each (the files API's default read), at most 2,000 of them and
  4 MiB in all; diffs and statuses up to the files API's own 1 MiB status
  cap. Two scripts in thirty seconds between them, inside the park's renewed
  lease and well inside the minute its caller waits for the whole park.

  ## What it is not

  - **Not a second read path.** The scripts are fixed, run through
    `Managoat.Sandbox.exec/4` like the files API's own, take paths as
    positional parameters, and are confined to the same roots by physical
    path. They run as the park's owner, not through `Machines.Reads`, because
    the row is already stamped `parking` and refuses every read.
  - **Not exposure.** Content is redacted *when it is taken*, with the values
    a live server has registered as well as the identity's — the inference
    credential and the callback token are only known while a server is up,
    and there will be none when the snapshot is read — and again when it is
    served. Both payloads are encrypted under the tenant's DEK.
  - **Not durable state.** One row per sandbox, replaced by the next park and
    removed when the machine stops for good. A capture that fails removes the
    previous one, so a picture is always of the last park or of nothing.
  - **Not required for a park.** Best effort, like the checkpoint beside it:
    any failure is logged and the park goes ahead.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Crypto
  alias Fountain.Repo
  alias Fountain.SandboxFiles
  alias Fountain.SandboxFiles.Snapshot

  require Logger

  @aad "fountain.sandbox_snapshot"
  @version 1

  @max_repos 16
  @max_paths 20_000
  @max_dirs 1_500
  @max_file_bytes 262_144
  @max_files 2_000
  @max_content_bytes 4_194_304
  # The bytes of paths handed to the collect script. Linux bounds a command
  # line at a couple of MiB including the environment; this stays well clear.
  @max_arg_bytes 524_288
  # The whole capture's time, and the survey's share of it. The park's caller
  # waits `Machine.park_timeout_ms/0` (a minute) for the checkpoint, this and
  # the suspend together; a caller that gives up reads the park as refused and
  # asks again a tick later, so the picture has to fit well inside that.
  @budget_ms 30_000
  @survey_ms 15_000

  @typedoc "One repository as the snapshot holds it. `diff` and the bodies may run one byte past the cap."
  @type repo :: %{
          root: String.t(),
          branch: String.t() | nil,
          diff: binary(),
          status_all: binary(),
          status_normal: binary()
        }

  @typedoc "What every listing, diff and status of a parked sandbox reads."
  @type manifest :: %{
          id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t(),
          taken_at: DateTime.t(),
          repos: [repo()],
          dirs: %{optional(String.t()) => %{entries: [map()], truncated: boolean()}},
          files: %{optional(String.t()) => non_neg_integer()}
        }

  @doc "Whether parks take a snapshot. On in production; tests turn it on where they want one."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fountain, __MODULE__, [])[:enabled] != false

  @doc "The largest file whose bytes are kept."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc "The most file bytes one snapshot keeps."
  @spec max_content_bytes() :: pos_integer()
  def max_content_bytes, do: @max_content_bytes

  @doc "How long a capture may take in all. `machine_bounds_test.exs` pins it under the park's ceiling."
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  # ── capture ────────────────────────────────────────────────────────────

  @doc """
  Take the picture of `sandbox`'s disk and store it in place of the last one.

  For `Fountain.Machines.Park` alone, which holds the machine's lease and has
  stamped it `parking`. Returns `{:ok, snapshot}`, `:skipped` when parks are
  not taking snapshots, or `{:error, reason}` once the previous snapshot has
  been removed. Never raises.

  `enabled: true` takes one whatever the configuration says, for a test.
  """
  @spec capture(Sandbox.t(), keyword()) :: {:ok, Snapshot.t()} | :skipped | {:error, term()}
  def capture(%Sandbox{} = sandbox, opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &enabled?/0) do
      taken_at = DateTime.utc_now()

      case take(sandbox) do
        {:ok, manifest, contents} ->
          store(sandbox, taken_at, manifest, contents)

        {:error, reason} = error ->
          forget(sandbox, reason)
          error
      end
    else
      :skipped
    end
  rescue
    error ->
      reason = Exception.format(:error, error, __STACKTRACE__)
      forget(sandbox, reason)
      {:error, :capture_raised}
  end

  defp forget(%Sandbox{} = sandbox, reason) do
    Logger.warning(
      "sandbox snapshot failed for #{sandbox.id} (#{sandbox.machine_name}); " <>
        "its files read as not ready while it is parked: #{inspect(reason)}"
    )

    delete(sandbox.id)
  end

  defp take(%Sandbox{} = sandbox) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    root = SandboxFiles.cwd(sandbox)
    roots = SandboxFiles.path_roots(sandbox)
    deadline = System.monotonic_time(:millisecond) + @budget_ms

    with {:ok, output} <-
           exec(
             handle,
             @survey_ms,
             survey_script(),
             [
               root,
               Integer.to_string(@max_repos),
               Integer.to_string(@max_paths),
               Integer.to_string(SandboxFiles.max_status_bytes() + 1)
             ] ++ roots
           ),
         {:ok, repos} <- parse_survey(output, root) do
      {dirs, files} = plan(root, repos)

      with {:ok, output} <-
             exec(
               handle,
               max(deadline - System.monotonic_time(:millisecond), 1_000),
               collect_script(),
               [Integer.to_string(@max_file_bytes), Integer.to_string(@max_content_bytes), root] ++
                 dirs ++ ["--"] ++ files
             ),
           {:ok, listings, picked, tarball} <- parse_collect(output),
           {:ok, contents} <- untar(tarball, picked, files, handle) do
        values = SandboxFiles.redaction_values(sandbox)

        {:ok, manifest(repos, dirs, listings, contents, values),
         redact_contents(contents, values)}
      end
    end
  end

  # `bash -c SCRIPT NAME ARGS…`, every absolute path through `host_path/2` for
  # the runner, exactly as `SandboxFiles` runs its own scripts.
  defp exec(handle, timeout, script, args) do
    args = Enum.map(args, &map_path(handle, &1))

    case Managoat.Sandbox.exec(handle, "bash", ["-c", script, "fountain-snapshot" | args],
           timeout: timeout
         ) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, output, code} -> {:error, {:exit, code, String.slice(output, 0, 200)}}
      {:error, reason} -> {:error, {:exec, reason}}
    end
  end

  defp map_path(handle, "/" <> _ = path), do: Managoat.Sandbox.host_path(handle, path)
  defp map_path(_handle, other), do: other

  # What to list and what to keep, from what the survey found. Directories are
  # every one a kept path sits in, up to its repository, and every one from
  # the working directory down to each repository, shallowest first. Files are
  # the changed ones first, then the rest shallowest first, and only ever in a
  # directory that is listed, so that a read the picture answers is a read the
  # listing beside it agrees with.
  @doc false
  @spec plan(String.t(), [map()]) :: {[String.t()], [String.t()]}
  def plan(root, repos) do
    dirs =
      repos
      |> Enum.flat_map(fn repo ->
        down_to_repo = between(root, repo.root)
        within = Enum.flat_map(repo.files, &between(repo.root, Path.dirname(&1)))
        down_to_repo ++ within
      end)
      |> Enum.concat([root])
      |> Enum.uniq()
      |> Enum.sort_by(&{depth(&1), &1})
      |> Enum.take(@max_dirs)

    listed = MapSet.new(dirs)
    changed = MapSet.new(Enum.flat_map(repos, & &1.changed))

    files =
      repos
      |> Enum.flat_map(& &1.files)
      |> Enum.filter(&MapSet.member?(listed, Path.dirname(&1)))
      |> Enum.sort_by(&{if(MapSet.member?(changed, &1), do: 0, else: 1), depth(&1), &1})
      |> Enum.take(@max_files)

    {dirs, within_arg_budget(dirs, files)}
  end

  # Every directory from `top` down to `dir`, both included. `dir` is under
  # `top` by construction; a pair that is not answers `[]`.
  defp between(top, dir) do
    if dir == top or String.starts_with?(dir, top <> "/") do
      dir
      |> Path.relative_to(top)
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.scan(top, &Path.join(&2, &1))
      |> then(&[top | &1])
    else
      []
    end
  end

  defp depth(path), do: path |> String.split("/") |> length()

  defp within_arg_budget(dirs, files) do
    used = Enum.reduce(dirs, 0, &(byte_size(&1) + 1 + &2))

    files
    |> Enum.reduce_while({used, []}, fn file, {used, kept} ->
      used = used + byte_size(file) + 1
      if used > @max_arg_bytes, do: {:halt, {used, kept}}, else: {:cont, {used, [file | kept]}}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp manifest(repos, dirs, listings, contents, values) do
    %{
      version: @version,
      repos:
        Enum.map(repos, fn repo ->
          %{
            root: repo.root,
            branch: repo.branch,
            diff: SandboxFiles.redact_bytes(values, repo.diff),
            status_all: SandboxFiles.redact_bytes(values, repo.status_all),
            status_normal: SandboxFiles.redact_bytes(values, repo.status_normal)
          }
        end),
      dirs: listed(dirs, listings, values),
      files: Map.new(contents, fn {path, bytes} -> {path, byte_size(bytes)} end)
    }
  end

  # The script names each listing by the index of the directory it was given.
  defp listed(dirs, listings, values) do
    dirs = List.to_tuple(dirs)

    listings
    |> Enum.filter(fn {index, _} -> index < tuple_size(dirs) end)
    |> Map.new(fn {index, listing} ->
      entries =
        Enum.map(listing.entries, &%{&1 | name: SandboxFiles.redact_bytes(values, &1.name)})

      {elem(dirs, index), %{listing | entries: entries}}
    end)
  end

  defp redact_contents(contents, values),
    do:
      Map.new(contents, fn {path, bytes} -> {path, SandboxFiles.redact_bytes(values, bytes)} end)

  # ── the scripts ────────────────────────────────────────────────────────

  @doc false
  @spec script(:survey | :collect) :: String.t()
  def script(:survey), do: survey_script()
  def script(:collect), do: collect_script()

  # The repositories under the working directory, each as a record per field,
  # NUL-framed because a path may hold a newline and cannot hold a NUL:
  #
  #   R <dir relative to the root> <branch>
  #   D <git diff, base64>   S <status -uall, base64>   N <status -unormal, base64>
  #   F <path relative to the repository>   (one per kept path)
  #
  # `find -P` does not follow a symlink, so nothing it finds is outside the
  # root it started from, and the root itself is confined the way every files
  # script confines its target. A `.git` is a directory or, in a worktree, a
  # file; either names a work tree, and it is kept only where git agrees that
  # this directory is that work tree's top. The directories pruned are the ones
  # that hold other people's repositories (a package cache, a dependency
  # tree), not the agent's.
  #
  # `GIT_OPTIONAL_LOCKS=0` for the reason the status script gives: a plain
  # status refreshes the index, and the read that observes the work must not
  # take `index.lock` from under it. The machine is idle here, but a hook or a
  # background job of the agent's need not be.
  defp survey_script do
    ~S"""
    root=$1
    max_repos=$2
    max_paths=$3
    git_bytes=$4
    shift 4
    [ -e "$root" ] || exit 3
    [ -d "$root" ] || exit 4
    physical=$(cd -- "$root" 2>/dev/null && pwd -P && printf '.') || exit 5
    physical=${physical%$'\n.'}
    outside=9
    """ <>
      SandboxFiles.physical_root_script() <>
      ~S"""
      cd -- "$physical" || exit 5
      export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0
      repos=0
      while IFS= read -r -d '' g; do
        [ "$repos" -ge "$max_repos" ] && break
        d=${g%/.git}
        rel=${d#.}
        rel=${rel#/}
        (
          cd -- "$d" 2>/dev/null || exit 1
          here=$(pwd -P && printf '.') || exit 1
          here=${here%$'\n.'}
          top=$(git rev-parse --show-toplevel 2>/dev/null && printf '.') || exit 1
          top=${top%$'\n.'}
          [ "$top" = "$here" ] || exit 1
          branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
          printf 'R\0%s\0%s\0' "$rel" "$branch"
          printf 'D\0'
          git --no-pager diff --no-color --no-ext-diff 2>/dev/null | head -c "$git_bytes" | base64
          printf '\0S\0'
          git --no-pager status --porcelain=v1 -z --untracked-files=all 2>/dev/null | head -c "$git_bytes" | base64
          printf '\0N\0'
          git --no-pager status --porcelain=v1 -z --untracked-files=normal 2>/dev/null | head -c "$git_bytes" | base64
          printf '\0'
          n=0
          while IFS= read -r -d '' f; do
            n=$((n + 1))
            [ "$n" -gt "$max_paths" ] && break
            printf 'F\0%s\0' "$f"
          done < <(git ls-files -z -co --exclude-standard 2>/dev/null)
        ) && repos=$((repos + 1))
      done < <(
        find . -maxdepth 5 \
          \( -name node_modules -o -name .cache -o -name .npm -o -name .cargo -o -name .rustup \
             -o -name .local -o -name _build -o -name deps -o -name vendor -o -name .venv \) -prune \
          -o -name .git -print0 -prune 2>/dev/null
      )
      exit 0
      """
  end

  # The listings, then the files, then their bytes:
  #
  #   L <index of the directory argument>, its entries as the files API's
  #     listing writes them (`type \t size \t name`), then E
  #   P <index of the file argument>   (one per file kept)
  #   T <tar.gz of the kept files, base64>
  #
  # Every directory and every file is checked again here, physically, against
  # the root the survey was confined to: the survey saw them a moment ago, and
  # a symlink is never followed. A file is kept while it is a regular file no
  # larger than the per-file cap and the running total stays within the
  # budget, in the order given, which is the order of preference.
  #
  # A listing stops one entry past the files API's entry cap, so `truncated`
  # means what it means there.
  defp collect_script do
    ~S"""
    cap=$1
    budget=$2
    root=$3
    shift 3
    proot=$(cd -- "$root" 2>/dev/null && pwd -P && printf '.') || exit 5
    proot=${proot%$'\n.'}
    inside() {
      case $1 in
        "$proot"|"$proot"/*) return 0 ;;
      esac
      return 1
    }
    i=0
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
      d=$1
      shift
      if [ -d "$d" ] && [ ! -L "$d" ]; then
        p=$(cd -- "$d" 2>/dev/null && pwd -P && printf '.')
        p=${p%$'\n.'}
        if [ -n "$p" ] && inside "$p"; then
          (
            cd -- "$d" 2>/dev/null || exit 0
            shopt -s dotglob nullglob
            printf 'L\0%s\0' "$i"
            n=0
            for f in *; do
              n=$((n + 1))
              [ "$n" -gt 2001 ] && break
              if [ -L "$f" ]; then t=symlink
              elif [ -d "$f" ]; then t=directory
              elif [ -f "$f" ]; then t=file
              else t=other; fi
              s=
              if [ "$t" = file ]; then s=$(wc -c < "$f" 2>/dev/null | tr -d ' '); fi
              printf '%s\t%s\t%s\0' "$t" "$s" "$f"
            done
            printf 'E\0'
          )
        fi
      fi
      i=$((i + 1))
    done
    [ "$#" -gt 0 ] && shift
    total=0
    i=0
    picked=()
    for f in "$@"; do
      if [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ]; then
        p=$(cd -- "${f%/*}" 2>/dev/null && pwd -P && printf '.')
        p=${p%$'\n.'}
        if [ -n "$p" ] && inside "$p"; then
          s=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          case $s in
            ''|*[!0-9]*) ;;
            *)
              if [ "$s" -le "$cap" ] && [ $((total + s)) -le "$budget" ]; then
                total=$((total + s))
                picked+=("$f")
                printf 'P\0%s\0' "$i"
              fi
              ;;
          esac
        fi
      fi
      i=$((i + 1))
    done
    printf 'T\0'
    if [ "${#picked[@]}" -gt 0 ]; then
      tar -cf - "${picked[@]}" 2>/dev/null | gzip -c | base64
    fi
    exit 0
    """
  end

  # ── parsing ────────────────────────────────────────────────────────────

  @doc false
  @spec parse_survey(binary(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_survey(output, root) do
    output
    |> :binary.split(<<0>>, [:global])
    |> survey_records(root, [])
  rescue
    _ -> {:error, :unparseable_survey}
  end

  defp survey_records([], _root, repos), do: {:ok, finish_repos(repos)}
  defp survey_records([""], _root, repos), do: {:ok, finish_repos(repos)}

  defp survey_records(["R", rel, branch | rest], root, repos) do
    repo_root = if rel == "", do: root, else: Path.join(root, rel)

    repo = %{
      root: repo_root,
      branch: if(branch == "", do: nil, else: branch),
      diff: "",
      status_all: "",
      status_normal: "",
      files: []
    }

    survey_records(rest, root, [repo | repos])
  end

  defp survey_records([tag, encoded | rest], root, [repo | repos]) when tag in ~w(D S N) do
    bytes = Base.decode64!(encoded, ignore: :whitespace)
    key = %{"D" => :diff, "S" => :status_all, "N" => :status_normal}[tag]
    survey_records(rest, root, [Map.put(repo, key, bytes) | repos])
  end

  defp survey_records(["F", path | rest], root, [repo | repos]) when path != "" do
    survey_records(rest, root, [
      %{repo | files: [Path.join(repo.root, path) | repo.files]} | repos
    ])
  end

  defp survey_records(_other, _root, _repos), do: {:error, :unparseable_survey}

  # Files in the order git gave them, the paths the status names as changed
  # (and still on disk to be read), and nothing kept past the path bound.
  defp finish_repos(repos) do
    repos
    |> Enum.reverse()
    |> Enum.map(fn repo ->
      files = repo.files |> Enum.reverse() |> Enum.take(@max_paths)
      %{repo | files: files} |> Map.put(:changed, changed_paths(repo))
    end)
  end

  defp changed_paths(repo) do
    repo.status_all
    |> SandboxFiles.status_changes()
    |> Enum.reject(&(&1.worktree == "deleted"))
    |> Enum.map(&Path.join(repo.root, &1.path))
  end

  @doc false
  @spec parse_collect(binary()) ::
          {:ok, [{non_neg_integer(), map()}], [non_neg_integer()], binary()} | {:error, term()}
  # A token that is exactly `T` is only ever the marker: an entry always holds
  # two tabs, and the other records are a letter followed by digits. The NUL
  # put in front is for output that is nothing but the marker.
  def parse_collect(output) do
    with [head, encoded] <- :binary.split(<<0>> <> output, <<0, "T", 0>>),
         {:ok, tarball} <- Base.decode64(encoded, ignore: :whitespace),
         ["" | tokens] <- :binary.split(head, <<0>>, [:global]),
         {:ok, listings, picked} <- collect_records(tokens, [], []) do
      {:ok, listings, picked, tarball}
    else
      _ -> {:error, :unparseable_collect}
    end
  end

  defp collect_records([], listings, picked),
    do: {:ok, Enum.reverse(listings), Enum.reverse(picked)}

  defp collect_records([""], listings, picked), do: collect_records([], listings, picked)

  defp collect_records(["L", index | rest], listings, picked) do
    {entries, rest} = Enum.split_while(rest, &(&1 != "E"))

    case rest do
      ["E" | rest] ->
        listing = listing(entries)
        collect_records(rest, [{String.to_integer(index), listing} | listings], picked)

      _ ->
        {:error, :unparseable_collect}
    end
  end

  defp collect_records(["P", index | rest], listings, picked),
    do: collect_records(rest, listings, [String.to_integer(index) | picked])

  defp collect_records(_other, _listings, _picked), do: {:error, :unparseable_collect}

  defp listing(records) do
    entries = SandboxFiles.parse_entries(Enum.map_join(records, &(&1 <> <<0>>)))

    %{
      entries: Enum.take(entries, SandboxFiles.max_entries()),
      truncated: length(entries) > SandboxFiles.max_entries()
    }
  end

  # The kept files' bytes, keyed by the path in the sandbox's own spelling.
  # The archive names them as the host saw them, less the leading `/` tar
  # strips, so each is matched back through the same `host_path/2` mapping
  # the arguments went out through.
  defp untar(_tarball, [], _files, _handle), do: {:ok, %{}}

  defp untar(tarball, picked, files, handle) do
    files = List.to_tuple(files)

    by_member =
      picked
      |> Enum.filter(&(&1 < tuple_size(files)))
      |> Map.new(fn index ->
        path = elem(files, index)
        {handle |> Managoat.Sandbox.host_path(path) |> String.trim_leading("/"), path}
      end)

    case :erl_tar.extract({:binary, tarball}, [:memory, :compressed]) do
      {:ok, members} ->
        {:ok,
         Enum.reduce(members, %{}, fn {name, bytes}, kept ->
           case Map.fetch(by_member, to_string(name)) do
             {:ok, path} -> Map.put(kept, path, bytes)
             :error -> kept
           end
         end)}

      {:error, reason} ->
        {:error, {:untar, reason}}
    end
  end

  # ── storage ────────────────────────────────────────────────────────────

  # One row per sandbox. A slower capture finishing after a newer one does
  # not replace it: the newer `taken_at` stands.
  defp store(%Sandbox{} = sandbox, taken_at, manifest, contents) do
    with {:ok, dek} <- Crypto.load_tenant_key(sandbox.user_id) do
      now = DateTime.utc_now()

      row = %{
        sandbox_id: sandbox.id,
        user_id: sandbox.user_id,
        taken_at: taken_at,
        manifest_ciphertext: seal(manifest, dek),
        contents_ciphertext: seal(contents, dek),
        file_count: map_size(contents),
        content_bytes: contents |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum(),
        inserted_at: now,
        updated_at: now
      }

      replace =
        from(s in Snapshot,
          where: s.taken_at < ^taken_at,
          update: [
            set: [
              taken_at: ^row.taken_at,
              manifest_ciphertext: ^row.manifest_ciphertext,
              contents_ciphertext: ^row.contents_ciphertext,
              file_count: ^row.file_count,
              content_bytes: ^row.content_bytes,
              updated_at: ^now
            ]
          ]
        )

      Repo.insert_all(Snapshot, [row], on_conflict: replace, conflict_target: :sandbox_id)

      Logger.info(
        "sandbox snapshot for #{sandbox.id}: #{row.file_count} files, " <>
          "#{row.content_bytes} bytes, #{map_size(manifest.dirs)} directories"
      )

      {:ok, Repo.get_by!(Snapshot, sandbox_id: sandbox.id)}
    else
      error -> {:error, {:tenant_key, error}}
    end
  end

  defp seal(term, dek),
    do: term |> :erlang.term_to_binary(compressed: 6) |> Crypto.encrypt(dek, @aad)

  # Authenticated decryption under the tenant's key already says these bytes
  # are ones `seal/2` wrote, but the decode still refuses anything executable
  # and any atom that does not exist: a stored term is data, never code.
  defp open(ciphertext, dek) do
    case Crypto.decrypt(ciphertext, dek, @aad) do
      {:ok, binary} -> {:ok, Plug.Crypto.non_executable_binary_to_term(binary, [:safe])}
      :error -> :error
    end
  end

  @doc """
  The snapshot of a sandbox that is parked right now, as a manifest, or nil.

  Only a `suspended` row has one worth reading: a machine that is up answers
  live, and one that has stopped has no disk to describe. The row is read
  here rather than taken from the caller, whose copy may be older than the
  wake that made the picture stale. The caller established ownership of the
  sandbox; the snapshot is read under the same tenant.
  """
  @spec parked(Sandbox.t()) :: manifest() | nil
  def parked(%Sandbox{id: sandbox_id, user_id: user_id}) do
    query =
      from(s in Snapshot,
        join: b in Sandbox,
        on: b.id == s.sandbox_id,
        where: s.sandbox_id == ^sandbox_id and s.user_id == ^user_id and b.status == "suspended",
        select: {s.id, s.taken_at, s.manifest_ciphertext}
      )

    with {id, taken_at, ciphertext} <- Repo.one(query),
         {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, %{version: @version} = manifest} <- open(ciphertext, dek) do
      manifest
      |> Map.take([:repos, :dirs, :files])
      |> Map.merge(%{id: id, user_id: user_id, taken_at: taken_at})
    else
      _ -> nil
    end
  end

  @doc "One kept file's bytes, as redacted when the snapshot was taken."
  @spec content(manifest(), String.t()) :: {:ok, binary()} | :error
  def content(%{id: id, user_id: user_id}, path) do
    with ciphertext when is_binary(ciphertext) <-
           Repo.one(
             from(s in Snapshot,
               where: s.id == ^id and s.user_id == ^user_id,
               select: s.contents_ciphertext
             )
           ),
         {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, contents} when is_map(contents) <- open(ciphertext, dek),
         {:ok, bytes} <- Map.fetch(contents, path) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  @doc """
  Remove a sandbox's snapshot: the capture that would replace it failed, or
  the machine has stopped for good. Best effort; a sandbox with none is fine.
  """
  @spec delete(Ecto.UUID.t()) :: :ok
  def delete(sandbox_id) when is_binary(sandbox_id) do
    Repo.delete_all(from(s in Snapshot, where: s.sandbox_id == ^sandbox_id))
    :ok
  rescue
    error ->
      Logger.warning(
        "sandbox snapshot for #{sandbox_id} was not removed: #{Exception.message(error)}"
      )

      :ok
  end
end
