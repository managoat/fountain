defmodule Fountain.ConversationsLogEventsBackwardTest do
  @moduledoc """
  Newest-first pages of a conversation's log (#2531): a client opens a long
  conversation at its newest turns instead of draining it from event one.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.LogEvent
  alias Fountain.Repo

  setup do
    {:ok, conv: insert_conversation()}
  end

  defp event(conv, turn, overrides \\ %{}) do
    insert_log_event(conv, Map.merge(%{turn_id: turn && turn.id}, Map.new(overrides)))
  end

  defp ids(events), do: Enum.map(events, & &1.id)

  defp page(conv, opts), do: Conversations._unsafe_list_log_events_backward(conv.id, opts)

  describe "backward paging" do
    test "returns the newest events newest first, then the ones before a cursor", %{conv: conv} do
      [e1, e2, e3, e4, e5] = for _ <- 1..5, do: event(conv, nil)

      first = page(conv, limit: 2)
      assert ids(first.events) == [e5.id, e4.id]
      assert first.has_more

      second = page(conv, limit: 2, before: e4.id)
      assert ids(second.events) == [e3.id, e2.id]
      assert second.has_more

      last = page(conv, limit: 2, before: e2.id)
      assert ids(last.events) == [e1.id]
      refute last.has_more
    end

    test "cursors come from rows, so sparse ids page correctly", %{conv: conv} do
      # Another conversation's rows sit between this one's: ids are global.
      other = insert_conversation()
      a = event(conv, nil)
      for _ <- 1..3, do: event(other, nil)
      b = event(conv, nil)
      for _ <- 1..3, do: event(other, nil)
      c = event(conv, nil)

      assert ids(page(conv, limit: 2).events) == [c.id, b.id]
      assert %{events: [^a], has_more: false} = page(conv, limit: 2, before: b.id)
    end

    test "has_more accounts for the stream filter", %{conv: conv} do
      a = event(conv, nil, stream: "stdout")
      event(conv, nil, stream: "stderr")
      b = event(conv, nil, stream: "stdout")

      assert %{events: events, has_more: false} = page(conv, limit: 2, streams: ["stdout"])
      assert ids(events) == [b.id, a.id]
    end
  end

  describe "whole_turns" do
    test "a page extends to its oldest turn's first event, past limit", %{conv: conv} do
      setup_events =
        for _ <- 1..2, do: event(conv, nil, kind: "stage", stream: "", stage: "setup")

      a = insert_turn(conv)
      a_events = for _ <- 1..5, do: event(conv, a)
      b = insert_turn(conv)
      b_events = for _ <- 1..4, do: event(conv, b)

      newest = page(conv, limit: 2, whole_turns: true)
      assert ids(newest.events) == b_events |> ids() |> Enum.reverse()
      assert newest.has_more
      refute newest.turn_split

      older = page(conv, limit: 2, whole_turns: true, before: List.last(newest.events).id)
      assert ids(older.events) == a_events |> ids() |> Enum.reverse()
      assert older.has_more

      # Turn-less setup events are not a turn: they page by limit alone.
      rest = page(conv, limit: 1, whole_turns: true, before: List.last(older.events).id)
      assert ids(rest.events) == [List.last(setup_events).id]
      assert rest.has_more
    end

    test "a page that ends on a turn's first event is not extended", %{conv: conv} do
      a = insert_turn(conv)
      a1 = event(conv, a)
      b = insert_turn(conv)
      [b1, b2] = for _ <- 1..2, do: event(conv, b)

      assert %{events: events, has_more: true} = page(conv, limit: 2, whole_turns: true)
      assert ids(events) == [b2.id, b1.id]

      assert %{events: [^a1], has_more: false} =
               page(conv, limit: 2, whole_turns: true, before: b1.id)
    end

    test "interleaved events of another turn pull that turn in whole", %{conv: conv} do
      # Turn A's closing stage lands after turn B has started, and a turn-less
      # sandbox stage sits inside B. A page holding any event of A holds all
      # of A, and the range keeps the turn-less row so no later page skips it.
      a = insert_turn(conv)
      b = insert_turn(conv)
      a1 = event(conv, a, kind: "stage", stream: "", stage: "turn", state: "started")
      a2 = event(conv, a)
      b1 = event(conv, b, kind: "stage", stream: "", stage: "turn", state: "started")
      x = event(conv, nil, kind: "stage", stream: "", stage: "sandbox", state: "done")
      a3 = event(conv, a, kind: "stage", stream: "", stage: "turn", state: "interrupted")
      b2 = event(conv, b)
      b3 = event(conv, b)

      assert %{events: events, has_more: false, turn_split: false} =
               page(conv, limit: 2, whole_turns: true)

      assert ids(events) == ids([b3, b2, a3, x, b1, a2, a1])
    end

    test "whole-turn paging of a long history visits every event once", %{conv: conv} do
      turns = for _ <- 1..6, do: insert_turn(conv)

      # Round-robin-ish interleaving plus turn-less rows between them.
      expected =
        for i <- 1..60 do
          turn = if rem(i, 7) == 0, do: nil, else: Enum.at(turns, div(i - 1, 10))
          event(conv, turn)
        end

      pages =
        Stream.unfold({nil, true}, fn
          {_before, false} ->
            nil

          {before, true} ->
            p = page(conv, limit: 3, whole_turns: true, before: before)
            {p, {List.last(p.events).id, p.has_more}}
        end)
        |> Enum.to_list()

      seen = pages |> Enum.flat_map(& &1.events) |> ids()
      assert seen == expected |> ids() |> Enum.reverse()

      # No turn straddles two pages.
      page_of_turn =
        for {p, n} <- Enum.with_index(pages), e <- p.events, e.turn_id, reduce: %{} do
          acc -> Map.update(acc, e.turn_id, MapSet.new([n]), &MapSet.put(&1, n))
        end

      assert Enum.all?(page_of_turn, fn {_turn, pages} -> MapSet.size(pages) == 1 end)
    end

    test "a turn larger than the ceiling is cut there and flagged", %{conv: conv} do
      a = insert_turn(conv)
      a_events = for _ <- 1..12, do: event(conv, a)
      a_desc = a_events |> ids() |> Enum.reverse()

      first = page(conv, limit: 2, whole_turns: true, max_events: 5)
      assert ids(first.events) == Enum.take(a_desc, 5)
      assert first.has_more
      assert first.turn_split

      second =
        page(conv, limit: 2, whole_turns: true, max_events: 5, before: List.last(first.events).id)

      assert ids(second.events) == Enum.slice(a_desc, 5, 5)
      assert second.turn_split

      third =
        page(conv,
          limit: 2,
          whole_turns: true,
          max_events: 5,
          before: List.last(second.events).id
        )

      assert ids(third.events) == Enum.slice(a_desc, 10, 2)
      refute third.has_more
      refute third.turn_split
    end

    test "with a stream filter the range keeps only matching rows", %{conv: conv} do
      a = insert_turn(conv)
      a1 = event(conv, a, stream: "stdout")
      event(conv, a, stream: "stderr")
      a3 = event(conv, a, stream: "stdout")
      a4 = event(conv, a, stream: "stdout")

      assert %{events: events, has_more: false} =
               page(conv, limit: 1, whole_turns: true, streams: ["stdout"])

      assert ids(events) == ids([a4, a3, a1])
    end

    test "another conversation's rows of the same turn id are never read", %{conv: conv} do
      # Defensive: turn ids belong to one conversation, but the probe still
      # names the conversation, so a forged row elsewhere cannot widen a page.
      a = insert_turn(conv)
      other = insert_conversation()
      event(other, a)
      a1 = event(conv, a)
      a2 = event(conv, a)

      assert %{events: events} = page(conv, limit: 1, whole_turns: true)
      assert ids(events) == ids([a2, a1])
    end
  end

  describe "a 7,000-event conversation" do
    @turns 70
    @per_turn 100

    setup %{conv: conv} do
      now = DateTime.utc_now()
      turns = for _ <- 1..@turns, do: insert_turn(conv)

      rows =
        for {turn, n} <- Enum.with_index(turns), i <- 1..@per_turn do
          %{
            conversation_id: conv.id,
            turn_id: turn.id,
            kind: if(i == 1, do: "stage", else: "output"),
            stream: if(i == 1, do: "", else: "stdout"),
            stage: if(i == 1, do: "turn", else: ""),
            state: if(i == 1, do: "started", else: ""),
            data: "turn #{n} line #{i}",
            inserted_at: now
          }
        end

      for chunk <- Enum.chunk_every(rows, 1000), do: Repo.insert_all(LogEvent, chunk)
      {:ok, turns: turns}
    end

    test "one request returns its newest complete turns", %{conv: conv, turns: turns} do
      {micros, page} =
        :timer.tc(fn -> page(conv, limit: 150, whole_turns: true, max_events: 5000) end)

      # 150 rows reach into the second-newest turn, which is completed.
      assert length(page.events) == 2 * @per_turn

      assert page.events |> Enum.map(& &1.turn_id) |> Enum.uniq() == [
               List.last(turns).id,
               Enum.at(turns, -2).id
             ]

      assert page.has_more

      # `FOUNTAIN_BENCH=1 mix test <this file>` prints the latency; asserting
      # on a wall-clock number would make CI's load the verdict.
      if System.get_env("FOUNTAIN_BENCH"),
        do: IO.puts("\n7,000 events, newest complete turns: 1 call, #{div(micros, 1000)} ms")
    end
  end
end
