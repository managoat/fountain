defmodule Managoat.Sandbox.Sprites.ProtocolContractTest do
  @moduledoc """
  A contract test against the `sprites` SDK's wire decoding, not against our
  own code.

  Sprites frames a finished command as stream id 3 followed by a **one-byte**
  exit code. The fork we pinned until #880 decoded that field as a 4-byte
  big-endian integer, so no real exit frame ever matched: every one fell
  through to `{:unknown, _}`, was dropped, and the socket's later close made
  `Sprites.Command` synthesise a `0`. Every one of the 533 exit codes Fountain
  had ever recorded was that synthetic zero — failing setup scripts and failed
  clones included.

  Nothing in Fountain can catch that regression, because `Sprites.exec/4` is
  correct either way; it faithfully reports whatever the SDK hands it. So the
  guard belongs here, on the dependency, where a future pin bump that reverts
  the decoding fails the build instead of silently disarming every exit code.

  The close-frame tests below guard the same seam from the other side. Until
  sprites 0.2.2 a socket that closed with no exit frame was reported as
  `{:exit, _, 0}` — the same fabricated success, arrived at by a different
  route. `Managoat.Sandbox` now forbids that, so a pin bump that puts the
  synthesised zero back fails here rather than in production.

  `Sprites.Command`'s state is a plain map and its `handle_info/2` is a
  public callback, so the close path is driven directly. Building the state
  by hand is the point: it is the SDK's own contract under test, not a
  connection.
  """

  use ExUnit.Case, async: true

  alias Sprites.Protocol

  @exit_id 3

  describe "exit frames decode as a single byte" do
    test "every code a process can actually exit with round-trips" do
      # 128 is git's `fatal:` (a silently-successful clone in #880); 255 is the
      # top of the POSIX range, which is why one byte is enough.
      for code <- [0, 1, 42, 127, 128, 130, 255] do
        assert Protocol.decode(<<@exit_id, code>>) == {:exit, code},
               "exit code #{code} did not decode; a dropped exit frame reports as success"
      end
    end

    test "a trailing byte does not stop the code being read" do
      assert Protocol.decode(<<@exit_id, 42, 0, 0, 0>>) == {:exit, 42}
    end

    test "an empty payload is the only case that defaults to 0" do
      assert Protocol.decode(<<@exit_id>>) == {:exit, 0}
    end

    test "a non-zero exit never decodes as :unknown" do
      refute match?({:unknown, _}, Protocol.decode(<<@exit_id, 1>>))
    end
  end

  describe "the other stream ids still mean what the adapter assumes" do
    test "stdout and stderr carry their payload verbatim" do
      assert Protocol.decode(<<1, "out">>) == {:stdout, "out"}
      assert Protocol.decode(<<2, "err">>) == {:stderr, "err"}
    end
  end

  describe "a close with no exit frame is an error, never a synthesised exit 0" do
    test "an empty mailbox at close time reports :closed_before_exit" do
      state = command_state()
      ref = state.ref

      assert {:stop, :normal, _state} = Sprites.Command.handle_info(close_frame(state), state)

      assert_receive {:error, %{ref: ^ref}, :closed_before_exit}
      refute_receive {:exit, %{ref: ^ref}, _}, 20
    end

    test "an exit frame still in flight at close time wins over the error" do
      # The race the drain exists for: the exit frame arrived on the socket
      # but had not been handled when the close came in. Reporting an error
      # here would fail a turn that actually finished.
      state = command_state()
      ref = state.ref

      send(self(), {:gun_ws, state.conn, state.stream_ref, {:binary, <<3, 7>>}})

      assert {:stop, :normal, _state} = Sprites.Command.handle_info(close_frame(state), state)

      assert_receive {:exit, %{ref: ^ref}, 7}
      refute_receive {:error, %{ref: ^ref}, _}, 20
    end

    # The SDK's own state map, minus the socket: `conn` and `stream_ref` only
    # have to match the frames we hand it. `using_control: true` keeps the
    # exit path from calling `:gun.ws_send/3` on a connection that is not one.
    defp command_state do
      %{
        owner: self(),
        ref: make_ref(),
        tty_mode: false,
        conn: make_ref(),
        stream_ref: make_ref(),
        exit_code: nil,
        token: "test-token",
        sprite: nil,
        using_control: true,
        control_conn: nil
      }
    end

    defp close_frame(state) do
      {:gun_ws, state.conn, state.stream_ref, {:close, 1000, ""}}
    end
  end
end
