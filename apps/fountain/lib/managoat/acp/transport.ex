defmodule Managoat.ACP.Transport do
  @moduledoc """
  The seam between the peer and whatever carries its bytes.

  It is one function. The peer's contract with the outside world is "bytes in
  by cast, bytes out by function": outbound frames go through the `writer`
  the host passed to `Managoat.ACP.Peer.start/1`, and inbound bytes arrive
  through `Managoat.ACP.Peer.stdout/2`, called from wherever the host's bytes
  come from. A sandbox owner forwards the `{:stdout, …}` message its sandbox
  sends it; a stdio host forwards a `Port` message; a test feeds a scripted
  reply. None of them has to be a process the library knows about.

  This is deliberately not a behaviour with a `read` callback, and not a
  process that owns the pipe. Reading is push-shaped on every transport the
  peer has run over (a sandbox command's stdout messages, a Port's
  `{port, {:data, _}}`, a WebSocket frame), so a pull-shaped `read/1` would
  be pretending to a symmetry that is not there, and a transport process
  would make the peer's lifetime depend on it. The `ref` a host passes to
  the peer stays the correlation token in every `{:acp, ref, payload}`
  report; the host matches on it however it likes.

  ## The writer

      @type writer :: (iodata() -> :ok | {:error, term()})

  The writer must be **total**: a transport that has gone away answers
  `{:error, reason}`, never raises and never exits the caller. The peer
  turns that error into one `{:failed, {:acp_write_failed, reason}}` report
  and stops writing; a writer that exits instead would take the peer down
  without a report, which for a turn in flight means a turn with no
  terminator at all.

  A writer that wraps a sandbox command:

      writer = fn iodata -> Managoat.Sandbox.write_stdin(command, iodata) end

  A writer over an Erlang port:

      writer = fn iodata ->
        if Port.info(port), do: (Port.command(port, iodata) && :ok), else: {:error, :closed}
      end

  A writer for a test, which hands the frame to the test process:

      test = self()
      writer = fn iodata -> send(test, {:wrote, IO.iodata_to_binary(iodata)}); :ok end

  The frames are newline-terminated JSON-RPC 2.0 objects, one per call
  (`Managoat.ACP.Protocol`), so a writer never has to frame anything.
  """

  @typedoc "Sends one newline-terminated frame. Total: errors are values."
  @type writer :: (iodata() -> :ok | {:error, term()})
end
