defmodule Fountain.LiveAdapterSandbox do
  @moduledoc """
  Where the live adapter suite (`test/live/adapter_behaviour_live_test.exs`)
  runs its adapters, and the parts of its Sprites checks that need no sandbox.

  The suite runs on E2B unless `LIVE_ADAPTER_SANDBOX=sprites` says otherwise.
  E2B is what `live-adapters.yml` and the release gate run, and nothing here
  changes what they do: same provider, same `fountain-live-adapter-<runtime>-<s>`
  names, which that workflow's cleanup step matches.

  Sprites is opt-in and run by hand. It is the provider the image-executable
  reuse in `Managoat.Runtimes.ACP` (`@image_reuse`) is gated on, so it is the
  only mode that exercises it. A Sprites token reaches every sprite in its
  organization and cannot be scoped to a prefix, so every name this mode makes
  starts with a prefix unique to the run (`run_prefix/1`), and a runtime only
  ever destroys the one name it created.

  Kept out of the live test file so the pure parts are tested in the ordinary
  suite (`Fountain.LiveAdapterSandboxTest`), which never talks to a provider.
  """

  @e2b_prefix "fountain-live-adapter-"

  @doc """
  The sandbox provider the suite runs on, from `LIVE_ADAPTER_SANDBOX`. Unset
  or blank is E2B. Anything else is refused rather than read as E2B: a typo
  must not quietly run the suite somewhere it was not asked to.
  """
  @spec mode(String.t() | nil) :: :e2b | :sprites
  def mode(value) do
    case value && String.trim(value) do
      blank when blank in [nil, ""] ->
        :e2b

      "e2b" ->
        :e2b

      "sprites" ->
        :sprites

      other ->
        raise ArgumentError, "LIVE_ADAPTER_SANDBOX must be e2b or sprites, got #{inspect(other)}"
    end
  end

  @doc "`mode/1` of the process environment."
  @spec mode() :: :e2b | :sprites
  def mode, do: mode(System.get_env("LIVE_ADAPTER_SANDBOX"))

  @doc """
  The name prefix of this run's sandboxes. E2B's is the fixed one its
  workflow's cleanup matches. Sprites' carries `unique`, so two runs, or a run
  and anything else in the organization, never share a name.
  """
  @spec run_prefix(:e2b | {:sprites, String.t()}) :: String.t()
  def run_prefix(:e2b), do: @e2b_prefix

  def run_prefix({:sprites, unique}) when is_binary(unique) do
    unless unique =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/,
      do: raise(ArgumentError, "a run id is lowercase letters, digits and inner hyphens")

    "#{@e2b_prefix}sprites-#{unique}-"
  end

  @doc "A fresh run id: the second it started and a random suffix."
  @spec run_id() :: String.t()
  def run_id do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{System.os_time(:second)}-#{suffix}"
  end

  @doc """
  The sandbox name for `runtime`. E2B's is the name it always had. A Sprites
  name is the run prefix and the runtime, nothing else, so the one name a
  runtime destroys on exit is exactly the one it created.
  """
  @spec name(:e2b | :sprites, String.t(), String.t()) :: String.t()
  def name(:e2b, @e2b_prefix, runtime), do: "#{@e2b_prefix}#{runtime}-#{System.os_time(:second)}"
  def name(:sprites, prefix, runtime), do: prefix <> runtime

  @doc """
  The Sprites adapter's settings for the suite. `public_urls: false`: the
  adapter makes a new sprite's URL public by default, for a person to open, and
  a test sprite has no such person.
  """
  @spec sprites_config(String.t(), String.t()) :: keyword()
  def sprites_config(token, base_url) do
    [token: token, base_url: base_url, timeout_ms: 60_000, public_urls: false]
  end

  @doc """
  A shell command listing every process: its pid, a tab, then its argv joined
  by the unit separator (0x1f). Read from /proc, so it needs no `ps`.
  """
  @spec process_listing() :: String.t()
  def process_listing do
    ~S"""
    for p in /proc/[0-9]*; do
      c=$(tr '\0' '\037' 2>/dev/null <"$p/cmdline") || continue
      [ -n "$c" ] && printf '%s\t%s\n' "${p#/proc/}" "$c"
    done
    true
    """
  end

  @doc "`process_listing/0`'s output as `[%{pid:, argv:}]`."
  @spec parse_processes(String.t()) :: [%{pid: pos_integer(), argv: [String.t()]}]
  def parse_processes(out) do
    for line <- String.split(out, "\n", trim: true),
        [pid, cmdline] <- [String.split(line, "\t", parts: 2)],
        {pid, ""} <- [Integer.parse(pid)] do
      %{pid: pid, argv: String.split(cmdline, "\x1f", trim: true)}
    end
  end

  @doc """
  The processes running `path`: as the program itself (a native CLI, the
  image's `codex`) or as the script an interpreter runs (`node <path>`).
  """
  @spec running(list(), String.t()) :: list()
  def running(processes, path) do
    Enum.filter(processes, fn %{argv: argv} -> path in Enum.take(argv, 2) end)
  end

  @doc """
  The processes running anything under `prefix`, the same two ways. Used for
  the bundled CLI's directory, where reuse means nothing runs.
  """
  @spec running_under(list(), String.t()) :: list()
  def running_under(processes, prefix) do
    Enum.filter(processes, fn %{argv: argv} ->
      Enum.any?(Enum.take(argv, 2), &String.starts_with?(&1, prefix))
    end)
  end

  @doc """
  A shell command reporting how `bin` was installed: the versioned install
  directory its PATH link points into, the executable recorded in `marker`
  there (if any) and whether it is executable, and the bundled CLI's packages
  present in the tree. `bundled` is the package path prefix relative to the
  install directory, as in `@image_reuse`.
  """
  @spec install_report(String.t(), String.t(), String.t()) :: String.t()
  def install_report(bin, marker, bundled) do
    """
    target=$(readlink /home/sprite/.local/bin/#{bin}) || { echo 'no link'; exit 0; }
    d=${target%/launch}
    printf 'dir\\t%s\\n' "$d"
    if [ -f "$d/#{marker}" ]; then
      read -r exe <"$d/#{marker}"
      printf 'executable\\t%s\\n' "$exe"
      [ -x "$exe" ] && printf 'executable_ok\\t1\\n'
      v=$(timeout 10 "$exe" --version 2>/dev/null | head -1) && printf 'version\\t%s\\n' "$v"
    fi
    for p in "$d"/#{bundled}*; do [ -e "$p" ] && printf 'bundled\\t%s\\n' "${p#"$d"/}"; done
    true
    """
  end

  @doc """
  `install_report/3`'s output as `%{dir:, executable:, executable_ok?:,
  version:, bundled: [...]}`; absent fields are nil (or `[]`, `false`).
  """
  @spec parse_install_report(String.t()) :: map()
  def parse_install_report(out) do
    init = %{dir: nil, executable: nil, executable_ok?: false, version: nil, bundled: []}

    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(init, fn line, acc ->
      case String.split(line, "\t", parts: 2) do
        ["dir", d] -> %{acc | dir: d}
        ["executable", e] -> %{acc | executable: e}
        ["executable_ok", "1"] -> %{acc | executable_ok?: true}
        ["version", v] -> %{acc | version: v}
        ["bundled", p] -> %{acc | bundled: acc.bundled ++ [p]}
        _ -> acc
      end
    end)
  end
end
