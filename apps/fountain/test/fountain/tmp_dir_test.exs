defmodule Fountain.TmpDirTest do
  @moduledoc """
  The scratch-path helper, and the guardrail that keeps the defect it fixes
  from coming back (#1423).

  The bug this replaces was not a wrong assertion anywhere. It was a path built
  from `System.unique_integer/1` alone, which is unique per BEAM node while
  `$TMPDIR` is shared by the whole host — so two concurrent `mix test` runs
  built the same path and deleted each other's files. It cost a session two
  false diagnoses, because the failure lands on whichever test was running and
  reads as a regression in that branch.

  CI cannot catch it: the six partitions each get their own machine. The
  guardrail below is what catches it instead, at review time, by refusing the
  spelling rather than the symptom.
  """

  use ExUnit.Case, async: true

  alias Fountain.TmpDir

  describe "path/1" do
    test "is scoped to this OS process, not just this node" do
      # The whole bug: a sibling `mix test` is a different OS process with its
      # own low unique integers, so the pid is the part that separates them.
      path = TmpDir.path("thing")

      assert Path.basename(path) =~ ~r/^thing-#{System.pid()}-\d+$/
      assert Path.dirname(path) == Path.dirname(TmpDir.path("other"))
    end

    test "two calls never agree" do
      assert TmpDir.path("thing") != TmpDir.path("thing")
    end

    test "creates nothing" do
      refute File.exists?(TmpDir.path("thing"))
    end
  end

  describe "mkdir!/1" do
    test "creates the directory and hands back the path" do
      dir = TmpDir.mkdir!("thing")

      assert File.dir?(dir)
      assert Path.basename(dir) =~ ~r/^thing-#{System.pid()}-\d+$/
    end

    test "removes it when the test ends, contents and all" do
      key = {__MODULE__, :cleanup_dir}

      # `on_exit` callbacks run last-registered-first, so this one — registered
      # *before* `mkdir!/1` registers its removal — is the one that runs after
      # it. The path travels through `:persistent_term` because the callback
      # runs in ExUnit's handler process, not this one, and the key is scoped
      # to this module so an async sibling cannot see it.
      on_exit(fn ->
        dir = :persistent_term.get(key)
        :persistent_term.erase(key)

        refute File.exists?(dir)
      end)

      dir = TmpDir.mkdir!("thing")
      :persistent_term.put(key, dir)
      File.write!(Path.join(dir, "f"), "x")

      assert File.exists?(Path.join(dir, "f"))
    end
  end

  describe "the guardrail" do
    # Every test file under apps/fountain/test; this file lives in
    # apps/fountain/test/fountain.
    # This file names the forbidden call in its own scan and in the assertion
    # above, so it is the one file the scan skips. Nothing else is exempt.
    @self Path.expand(__ENV__.file)

    defp test_files do
      root = Path.expand("../..", __DIR__)

      root
      |> Path.join("test/**/*.exs")
      |> Path.wildcard()
      |> Enum.reject(&(Path.expand(&1) == @self))
    end

    test "no test builds its own $TMPDIR path" do
      offenders =
        for file <- test_files(),
            line <- String.split(File.read!(file), "\n"),
            String.contains?(line, "System.tmp_dir"),
            do: "#{Path.relative_to_cwd(file)}: #{String.trim(line)}"

      assert offenders == [],
             """
             These build a scratch path under the shared $TMPDIR themselves.
             Two concurrent `mix test` runs will collide on it — see
             `Fountain.TmpDir`. Use `Fountain.TmpDir.mkdir!/1` for a directory,
             or `Fountain.TmpDir.path/1` when you want the path alone:

             #{Enum.join(offenders, "\n")}
             """
    end

    test "the guardrail is looking at the files it thinks it is" do
      # Guard the guard (#406): an empty or mis-rooted glob would make the test
      # above pass over nothing.
      files = test_files()

      assert length(files) > 100
      # A file from the deeper half of apps/fountain/test, so a glob that only
      # reached the top level would still fail here. It used to name a Buzz
      # test; those live in apps/fountain_buzz since #1507, which this
      # guardrail's roots deliberately do not cover.
      assert Enum.any?(files, &String.contains?(&1, "/conversations/attach_test.exs"))
    end
  end
end
