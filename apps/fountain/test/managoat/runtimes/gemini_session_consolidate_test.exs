defmodule Managoat.Runtimes.GeminiSessionConsolidateTest do
  @moduledoc """
  The gemini session-store workaround (#659), exercised as the script that
  actually runs — node against real files on disk, not a re-implementation.

  Fixtures mirror what a live 0.56.0 leaves behind, measured on 2026-08-22:
  turn 1 writes `session-<ISO minute>-<id8>.jsonl` with the transcript in it,
  and every `session/load` adds a second file under the *same* naming scheme
  carrying only a `$set` with gemini's `<session_context>` bootstrap.
  """
  use ExUnit.Case, async: true

  @script Path.join([
            __DIR__,
            "..",
            "..",
            "..",
            "priv",
            "runtimes",
            "gemini-session-consolidate.js"
          ])
          |> Path.expand()

  @parked "0000-00-00T00-00"

  setup do
    home = Fountain.TmpDir.mkdir!("gsc")
    chats = Path.join([home, ".gemini", "tmp", "projecthash", "chats"])
    File.mkdir_p!(chats)
    {:ok, home: home, chats: chats}
  end

  defp msg(type, text),
    do: %{"type" => type, "content" => text, "id" => "m#{:rand.uniform(9999)}"}

  # A real session file: metadata line, then message records.
  defp write_session(chats, name, sid, n_messages) do
    lines =
      ([
         %{
           "sessionId" => sid,
           "projectHash" => "projecthash",
           "startTime" => "2026-08-22T06:22:00Z"
         }
       ] ++
         Enum.flat_map(1..max(n_messages, 0)//1, fn i ->
           [msg("user", "q#{i}"), msg("gemini", "a#{i}")]
         end))
      |> Enum.take(n_messages)

    body = Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n"
    File.write!(Path.join(chats, name), body)
  end

  # What a load leaves: the bootstrap-only `$set` that erases the transcript.
  defp write_poisoned(chats, name, sid) do
    lines = [
      %{"sessionId" => sid, "projectHash" => "projecthash"},
      %{"$set" => %{"messages" => [%{"type" => "user", "content" => "<session_context>…"}]}}
    ]

    File.write!(Path.join(chats, name), Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  defp run(home, sid) do
    {out, code} =
      System.cmd("node", [@script, sid], env: [{"HOME", home}], stderr_to_stdout: true)

    assert code == 0, "script failed: #{out}"
    Jason.decode!(String.trim(out))
  end

  defp files(chats), do: chats |> File.ls!() |> Enum.sort()

  test "the script exists where the runtime expects it" do
    assert File.exists?(@script)
  end

  test "parks a first-turn session out of the collision path", ctx do
    sid = "aaaaaaaa-1111-2222-3333-444444444444"
    write_session(ctx.chats, "session-2026-08-22T06-22-aaaaaaaa.jsonl", sid, 3)

    assert %{"kept" => 1, "removed" => 0} = run(ctx.home, sid)
    assert files(ctx.chats) == ["session-#{@parked}-aaaaaaaa.jsonl"]
  end

  test "keeps the transcript and deletes the poisoned duplicate a load leaves", ctx do
    # The case that breaks a naive rename: two files, same sessionId, and
    # gemini would pick the poisoned one because its lastUpdated is later.
    sid = "bbbbbbbb-1111-2222-3333-444444444444"
    write_session(ctx.chats, "session-#{@parked}-bbbbbbbb.jsonl", sid, 5)
    write_poisoned(ctx.chats, "session-2026-08-22T06-23-bbbbbbbb.jsonl", sid)

    assert %{"kept" => 1, "removed" => 1} = run(ctx.home, sid)
    assert files(ctx.chats) == ["session-#{@parked}-bbbbbbbb.jsonl"]

    kept = File.read!(Path.join(ctx.chats, "session-#{@parked}-bbbbbbbb.jsonl"))
    assert kept =~ "q1"
    refute kept =~ "session_context"
  end

  test "never touches another session's files", ctx do
    # One conversation per sandbox today, but a persistent sandbox (ADR 0023)
    # puts several on one disk and this is the invariant that has to hold.
    mine = "cccccccc-1111-2222-3333-444444444444"
    theirs = "dddddddd-1111-2222-3333-444444444444"
    write_session(ctx.chats, "session-2026-08-22T06-22-cccccccc.jsonl", mine, 3)
    write_session(ctx.chats, "session-2026-08-22T06-22-dddddddd.jsonl", theirs, 3)

    assert %{"kept" => 1, "removed" => 0} = run(ctx.home, mine)

    assert files(ctx.chats) == [
             "session-#{@parked}-cccccccc.jsonl",
             "session-2026-08-22T06-22-dddddddd.jsonl"
           ]
  end

  test "is idempotent — a second run changes nothing", ctx do
    sid = "eeeeeeee-1111-2222-3333-444444444444"
    write_session(ctx.chats, "session-2026-08-22T06-22-eeeeeeee.jsonl", sid, 3)

    run(ctx.home, sid)
    before = File.read!(Path.join(ctx.chats, "session-#{@parked}-eeeeeeee.jsonl"))

    assert %{"kept" => 1, "removed" => 0} = run(ctx.home, sid)
    assert files(ctx.chats) == ["session-#{@parked}-eeeeeeee.jsonl"]
    assert File.read!(Path.join(ctx.chats, "session-#{@parked}-eeeeeeee.jsonl")) == before
  end

  test "richest wins even when the parked file is the poorer one", ctx do
    # The discriminating case. If the rule were "prefer whatever is already
    # parked" this passes anyway, so the parked file is deliberately the one
    # with *less* content: only a genuine richest-wins comparison keeps the
    # six-message transcript here.
    sid = "ffffffff-1111-2222-3333-444444444444"
    write_session(ctx.chats, "session-#{@parked}-ffffffff.jsonl", sid, 2)
    write_session(ctx.chats, "session-2026-08-22T06-30-ffffffff.jsonl", sid, 6)

    assert %{"kept" => 1, "removed" => 1} = run(ctx.home, sid)
    assert files(ctx.chats) == ["session-#{@parked}-ffffffff.jsonl"]

    kept = File.read!(Path.join(ctx.chats, "session-#{@parked}-ffffffff.jsonl"))
    assert kept =~ "q3", "kept the poorer file: richest-wins did not apply"
  end

  test "a tie keeps the already-parked file, so repeat runs are stable", ctx do
    sid = "77777777-1111-2222-3333-444444444444"
    write_session(ctx.chats, "session-#{@parked}-77777777.jsonl", sid, 4)
    write_session(ctx.chats, "session-2026-08-22T06-30-77777777.jsonl", sid, 4)

    assert %{"kept" => 1, "removed" => 1} = run(ctx.home, sid)
    assert files(ctx.chats) == ["session-#{@parked}-77777777.jsonl"]
  end

  test "a turn that wrote no session is not an error", ctx do
    assert %{"kept" => 0, "removed" => 0} =
             run(ctx.home, "99999999-1111-2222-3333-444444444444")
  end

  test "a missing .gemini directory is not an error" do
    home = Fountain.TmpDir.mkdir!("gsc-empty")

    {out, 0} =
      System.cmd("node", [@script, "aaaaaaaa-1111-2222-3333-444444444444"],
        env: [{"HOME", home}],
        stderr_to_stdout: true
      )

    assert %{"kept" => 0} = Jason.decode!(String.trim(out))
  end
end
