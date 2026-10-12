defmodule Fountain.TmpDir do
  @moduledoc """
  Scratch paths under `$TMPDIR` that two concurrent suites cannot collide on
  (#1423).

  The obvious spelling is wrong in a way that only shows up on a developer's
  machine:

      Path.join(System.tmp_dir!(), "thing-\#{System.unique_integer([:positive])}")

  `System.unique_integer/1` is unique **per BEAM node**, not per machine, while
  `$TMPDIR` is shared by every process on the host. Two `mix test` runs are two
  nodes, so both counters start low and hand out the same small integers, and
  both runs then build the same path. Whichever finishes first deletes the
  directory the other is still working in.

  It is invisible in CI, where the six partitions each get a machine to
  themselves, and it appears exactly when several worktrees or agents build in
  parallel — where it reads as a regression in whichever branch happened to be
  running. `Fountain.Buzz.HarnessTest` is the one that was seen failing,
  because it launches a real OS process out of the directory and so has the
  widest window between `mkdir_p!` and use; the other five call sites had the
  same defect with a narrower window.

  Adding `System.pid/0` — the BEAM's OS pid — makes the path unique per *run*,
  which is the scope that was missing. The unique integer stays for uniqueness
  within a run.

  ## Use

      # a directory, made and cleaned up for you
      dir = Fountain.TmpDir.mkdir!("my-harness")

      # just the path, when the caller owns creation and cleanup
      file = Fountain.TmpDir.path("my-binary")
  """

  @doc """
  A collision-free path under `$TMPDIR` beginning with `prefix`.

  Creates nothing. For a caller that wants the path itself — a file rather
  than a directory, or cleanup on its own schedule.
  """
  @spec path(String.t()) :: String.t()
  def path(prefix) when is_binary(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  @doc """
  `path/1`, created, and removed again when the test ends.

  The `on_exit` is registered here so that the cleanup and the path can never
  drift apart. It stacks with any other `on_exit` the caller registers, so a
  test that also restores application env keeps doing that.

  Callable from `setup` or from a test body — anywhere `ExUnit.Callbacks.on_exit/1`
  is.
  """
  @spec mkdir!(String.t()) :: String.t()
  def mkdir!(prefix) when is_binary(prefix) do
    dir = path(prefix)
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
