defmodule Fountain.HelpTest do
  @moduledoc """
  The help topic list against what is actually on disk.

  There used to be two hand-maintained copies of this list — one in
  `HelpLive.Show`, one in `LlmsController`, with a comment on the second saying
  "keep them in sync". They were not: `/llms.txt` advertised
  `/help/secrets-managers`, which the in-app list did not know, so following the
  link flashed "No such help topic" and redirected. The reverse hole existed
  too — `skills` was in the nav and missing from the bundle.

  One list now, and these check it in both directions so the next drift is a
  test failure rather than a dead link.
  """

  use ExUnit.Case, async: true

  alias Fountain.Help

  test "every topic has a markdown file" do
    missing = Help.slugs() -- Help.files()
    assert missing == [], "topics with no file in priv/help: #{inspect(missing)}"
  end

  test "every markdown file is a listed topic" do
    # The direction that produced the original bug: a file exists and is served
    # in /llms-full.txt while the nav hides it.
    unlisted = Help.files() -- Help.slugs()
    assert unlisted == [], "files in priv/help with no topic entry: #{inspect(unlisted)}"
  end

  test "slugs are unique" do
    assert Enum.uniq(Help.slugs()) == Help.slugs()
  end

  test "the topic that started this is present" do
    assert "secrets-managers" in Help.slugs()
    assert "skills" in Help.slugs()
  end
end
