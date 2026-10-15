defmodule Managoat.Runtimes.Gemini.SessionStore do
  @moduledoc """
  A workaround, registered as `:gemini_session_store_consolidation` in
  `Managoat.Runtimes.Quirks` — which carries the deletion condition and how
  to re-probe it. This whole module goes when gemini-cli#28775 lands.

  Keeps gemini's own chat-session store from erasing the session it is asked to
  load — a workaround for [gemini-cli#28775][], tracked as #659.

  [gemini-cli#28775]: https://github.com/google-gemini/gemini-cli/issues/28775

  ## What goes wrong without this

  Measured against a live `gemini --acp` on 2026-08-22, versions 0.53.0 through
  0.56.0. `session/load` builds a fresh config on the session id *before*
  looking the session up, which stands up a chat recorder; the recorder's
  new-session branch names its file by **wall-clock minute**
  (`toISOString().slice(0, 16)`) plus the id's first 8 characters, so a load in
  the same minute as the last write computes the *same path*; it appends a
  `$set` carrying only gemini's `<session_context>` bootstrap; and gemini's
  reader treats `$set.messages` as a replacement rather than a merge. The
  emptied file then fails `hasResumableContent`, drops out of `listSessions()`,
  and `findSession` reports `-32603` "No previous sessions found for this
  project" — about a session whose transcript is still on disk, above the line
  that erased it.

  Reproduced end to end: a turn-1 file with three resumable messages had one
  left after a same-minute load, and the load failed.

  ## Why a rename is not enough

  The obvious fix — move the file out of the minute-bucketed path — holds for
  exactly one turn. After every load **two** files carry the same `sessionId`:
  the one we parked and the poisoned one the load just created. Gemini dedupes
  by id keeping the later `lastUpdated`, which is the poisoned one, so turn 3
  fails again.

  So this **consolidates** on every turn instead: keep the file with real
  content, delete the poisoned duplicates, and park the survivor under a
  timestamp the recorder can never produce. Discovery is unaffected — gemini
  scans on the `session-` prefix and the extension, and matches on the
  `sessionId` *inside* the file, never on the name.

  Verified live: five consecutive turns inside one wall-clock minute (the case
  that fails on turn 2 without this), history growing 3 → 5 → 7 → 9 → 11, and
  the agent recalling content planted before the first reload every time.

  ## Lifetime

  Delete this module, `priv/runtimes/gemini-session-consolidate.js`, and the host's
  end-of-turn `consolidate/2` call when upstream lands. Nothing else depends
  on it.
  """

  require Logger

  @script_path "/tmp/gemini-session-consolidate.js"

  @source Path.expand("../../../../priv/runtimes/gemini-session-consolidate.js", __DIR__)
  @external_resource @source
  @script File.read!(@source)

  @doc """
  Install the consolidation script into the sandbox.

  Called from `Gemini.prepare_sandbox/3`. Written to `/tmp` because gemini runs
  with `HOME=/tmp` on the sprite and `/tmp` is writable there without the ACL
  surprises `/home/sprite` has.
  """
  @spec install(Managoat.Sandbox.Handle.t()) :: :ok | {:error, term()}
  def install(handle) do
    Managoat.Sandbox.write_file(handle, @script_path, @script)
  end

  @doc """
  Consolidate this session's chat files. Best-effort by contract.

  Called at the end of every gemini ACP turn, before the next turn's
  `session/load` can collide. A failure here costs the *next* turn its history,
  which is bad, but failing the turn that just succeeded would be worse — so
  this logs and returns `:ok` rather than propagating.

  Runs with `HOME=/tmp` to match `Gemini.default_env/2`; the script resolves the
  chats directory from `HOME` exactly as gemini does.
  """
  @spec consolidate(Managoat.Sandbox.Handle.t(), String.t() | nil) :: :ok
  def consolidate(_handle, session_id) when session_id in [nil, ""], do: :ok

  def consolidate(handle, session_id) do
    case Managoat.Sandbox.exec(handle, "node", [@script_path, session_id],
           env: [{"HOME", "/tmp"}],
           timeout: 15_000
         ) do
      {:ok, out, 0} ->
        Logger.debug("gemini session consolidate: #{String.trim(to_string(out))}")
        :ok

      {:ok, out, code} ->
        Logger.warning(
          "gemini session consolidate exited #{code} for #{session_id}: " <>
            String.trim(to_string(out))
        )

        :ok

      {:error, reason} ->
        Logger.warning("gemini session consolidate failed for #{session_id}: #{inspect(reason)}")

        :ok
    end
  end

  @doc false
  def script_path, do: @script_path
end
