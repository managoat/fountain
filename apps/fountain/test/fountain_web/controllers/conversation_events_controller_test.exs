defmodule FountainWeb.ConversationEventsControllerTest do
  @moduledoc """
  The JSON read-model for a conversation's log feed (#519).

  Before this, the only access to log events over the API was the SSE stream —
  so anything wanting to fetch, archive or analyse a conversation's output had
  to implement an event-stream parser for what is a paginated list read.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    conv = insert_conversation(user_id: user.id)
    {:ok, user: user, key: key, conv: conv}
  end

  defp get_events(conn, key, conv, query \\ "") do
    conn |> authed_with_key(key) |> get("/api/conversations/#{conv.id}/events" <> query)
  end

  defp body_of(conn, key, conv) do
    conn |> get_events(key, conv) |> json_response(200) |> Map.fetch!("data")
  end

  describe "GET /api/conversations/:id/events" do
    test "returns the feed oldest-first with the SSE payload's fields", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      first = insert_log_event(conv, kind: "output", stream: "stdout", data: "hello")
      second = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      body = conn |> get_events(key, conv) |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [first.id, second.id]

      assert %{
               "id" => _,
               "kind" => "output",
               "stream" => "stdout",
               "data" => "hello",
               "stage" => _,
               "state" => _,
               "duration_ms" => _,
               "turn_id" => _,
               "ts" => _
             } = hd(body["data"])
    end

    test "an event with no state or stage renders them null, not \"\" (#1430)", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # The schema declares `state` as one of four values or null, and the
      # server used to answer `""` — neither. This is the busiest read in the
      # API and all four SDKs decode the field, so a strict enum decoder was
      # entitled to reject an ordinary output line.
      insert_log_event(conv, kind: "output", stream: "stdout", data: "hello")

      assert %{"state" => nil, "stage" => nil} = hd(body_of(conn, key, conv))
    end

    test "a stage event still renders its real stage and state", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # Guard the guard: a conversion that nilled everything would satisfy the
      # test above and lose the field's entire meaning.
      insert_log_event(conv, kind: "stage", stream: "", stage: "provision", state: "done")

      assert %{"stage" => "provision", "state" => "done"} = hd(body_of(conn, key, conv))
    end

    test "an empty feed is an empty page, not an error", %{conn: conn, key: key, conv: conv} do
      body = conn |> get_events(key, conv) |> json_response(200)

      assert body["data"] == []
      assert body["meta"]["has_more"] == false
      assert body["meta"]["next_cursor"] == nil
    end

    test "filters by stream, with the same semantics as the SSE route", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      out = insert_log_event(conv, kind: "output", stream: "stdout", data: "o")
      err = insert_log_event(conv, kind: "output", stream: "stderr", data: "e")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "boot")

      ids = fn query ->
        conn |> get_events(key, conv, query) |> json_response(200) |> Map.fetch!("data")
      end

      assert ids.("?streams=stdout") |> Enum.map(& &1["id"]) == [out.id]
      assert ids.("?streams=stage") |> Enum.map(& &1["id"]) == [stage.id]

      assert ids.("?streams=stderr,stage") |> Enum.map(& &1["id"]) == [err.id, stage.id]
    end

    test "an unknown stream name returns nothing rather than everything", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      insert_log_event(conv, kind: "output", stream: "stdout")

      body = conn |> get_events(key, conv, "?streams=bogus") |> json_response(200)
      assert body["data"] == []
    end
  end

  describe "GET /api/conversations/:id/events?prompts=true" do
    # A conversation's log feed is everything the runtime wrote and nothing the
    # human typed, so a client replaying one renders it as a monologue in the
    # agent's voice. The prompt is already on the turn; this fills the turn's
    # own `turn`/`started` stage event, whose `blocks` was otherwise always [].
    defp turn_with_start(conv, overrides) do
      turn = insert_turn(conv, overrides)

      event =
        insert_log_event(conv,
          kind: "stage",
          stream: "",
          stage: "turn",
          state: "started",
          turn_id: turn.id,
          data: Jason.encode!(%{turn_id: turn.id})
        )

      {turn, event}
    end

    defp blocks_by_id(conn, key, conv, query) do
      conn
      |> get_events(key, conv, query)
      |> json_response(200)
      |> Map.fetch!("data")
      |> Map.new(&{&1["id"], &1["blocks"]})
    end

    test "the prompt is absent until asked for", %{conn: conn, key: key, conv: conv} do
      {_turn, start} = turn_with_start(conv, %{prompt: "make the heading blue"})

      # No `blocks` key at all without `blocks=true` — the default response
      # shape does not move.
      refute conn
             |> get_events(key, conv)
             |> json_response(200)
             |> Map.fetch!("data")
             |> hd()
             |> Map.has_key?("blocks")

      assert blocks_by_id(conn, key, conv, "?blocks=true")[start.id] == []
    end

    test "asked for, the turn's stage event carries one prompt block", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      {_turn, start} = turn_with_start(conv, %{prompt: "make the heading blue"})
      output = insert_log_event(conv, kind: "output", stream: "stdout", data: "ok")

      blocks = blocks_by_id(conn, key, conv, "?blocks=true&prompts=true")

      assert blocks[start.id] == [%{"kind" => "prompt", "body" => "make the heading blue"}]
      # Only the anchor. A non-ACP output row still parses to nothing.
      assert blocks[output.id] == []
    end

    test "each turn's prompt lands on that turn's own stage event", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      {_first, first_start} = turn_with_start(conv, %{prompt: "first"})
      {_second, second_start} = turn_with_start(conv, %{prompt: "second"})

      blocks = blocks_by_id(conn, key, conv, "?blocks=true&prompts=true")

      assert blocks[first_start.id] == [%{"kind" => "prompt", "body" => "first"}]
      assert blocks[second_start.id] == [%{"kind" => "prompt", "body" => "second"}]
    end

    test "a read-only turn's prompt block says so, and only that one (#2533)", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      {_normal, normal_start} = turn_with_start(conv, %{prompt: "fix it"})
      {_asked, asked_start} = turn_with_start(conv, %{prompt: "why?", read_only: true})

      blocks = blocks_by_id(conn, key, conv, "?blocks=true&prompts=true")

      assert blocks[normal_start.id] == [%{"kind" => "prompt", "body" => "fix it"}]

      assert blocks[asked_start.id] == [
               %{"kind" => "prompt", "body" => "why?", "read_only" => true}
             ]
    end

    test "a stage event that is not a turn start stays empty", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      {_turn, start} = turn_with_start(conv, %{prompt: "hello"})

      done =
        insert_log_event(conv, kind: "stage", stream: "", stage: "turn", state: "done")

      provision = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      blocks = blocks_by_id(conn, key, conv, "?blocks=true&prompts=true")

      assert blocks[start.id] != []
      assert blocks[done.id] == []
      assert blocks[provision.id] == []
    end

    test "an autonomous turn contributes no prompt (#817)", %{conn: conn, key: key, conv: conv} do
      # Its prompt is a placeholder the server wrote for a cycle nobody asked
      # for. Rendering it in the human's voice would put words in his mouth.
      {_turn, start} =
        turn_with_start(conv, %{prompt: "(background task follow-up)", origin: "autonomous"})

      assert blocks_by_id(conn, key, conv, "?blocks=true&prompts=true")[start.id] == []
    end

    test "prompts=true without blocks=true changes nothing", %{conn: conn, key: key, conv: conv} do
      turn_with_start(conv, %{prompt: "hello"})

      plain = conn |> get_events(key, conv) |> json_response(200)
      asked = conn |> get_events(key, conv, "?prompts=true") |> json_response(200)

      assert plain == asked
    end

    test "no event is added, so the cursor and page accounting do not move", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # The hazard the anchor exists to avoid: `meta.next_cursor` is the last
      # row's id, so a fabricated event would hand a client a cursor no row has
      # and corrupt its resume.
      for _ <- 1..3, do: turn_with_start(conv, %{prompt: "p"})

      without = conn |> get_events(key, conv, "?blocks=true&limit=2") |> json_response(200)
      with_p = conn |> get_events(key, conv, "?blocks=true&prompts=true&limit=2")
      with_p = json_response(with_p, 200)

      assert with_p["meta"] == without["meta"]
      assert Enum.map(with_p["data"], & &1["id"]) == Enum.map(without["data"], & &1["id"])

      next =
        conn
        |> get_events(
          key,
          conv,
          "?blocks=true&prompts=true&limit=2&after=#{with_p["meta"]["next_cursor"]}"
        )
        |> json_response(200)

      assert Enum.map(next["data"], & &1["id"]) ==
               conn
               |> get_events(
                 key,
                 conv,
                 "?blocks=true&limit=2&after=#{without["meta"]["next_cursor"]}"
               )
               |> json_response(200)
               |> Map.fetch!("data")
               |> Enum.map(& &1["id"])
    end

    test "streams=acp drops the stage events and the prompts with them", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # Documented rather than special-cased: the stream filter is older than
      # this parameter and excludes every stage event, prompt-bearing or not.
      turn_with_start(conv, %{prompt: "hello"})

      body =
        conn
        |> get_events(key, conv, "?blocks=true&prompts=true&streams=acp")
        |> json_response(200)

      assert body["data"] == []
    end

    # Everything above asserts the response body, and the body is the same
    # whether the prompts came from the page's own turns or from re-reading the
    # conversation. The two below assert the work instead, which is the only
    # way this stays bounded: `?prompts=true` used to hand the whole
    # conversation to `_unsafe_list_turns/1`, images preloaded, per page.
    defp watch_turn_reads do
      me = self()
      handler = "events-prompts-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:fountain, :repo, :query],
        fn _event, _measure, meta, _config ->
          if self() == me and meta[:source] in ["turns", "turn_images"] do
            send(me, {:read, meta[:source], rows_returned(meta)})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp rows_returned(%{result: {:ok, %{num_rows: rows}}}), do: rows
    defp rows_returned(_meta), do: :unknown

    # `{source, rows}` per query since `watch_turn_reads/0`, in order.
    defp turn_reads(acc \\ []) do
      receive do
        {:read, source, rows} -> turn_reads([{source, rows} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp with_image(turn) do
      {:ok, 1} =
        Conversations._unsafe_insert_turn_images(turn.id, [
          %{media_type: "image/png", data: <<137, 80, 78, 71, 13, 10, 26, 10>>}
        ])

      turn
    end

    test "hydration reads the page's turn and no image row at all", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # Four turns, each carrying an image. The old lookup read all four turns
      # and preloaded all four image rows, `data` column included, to render a
      # page holding one of them; an accepted prompt image may be 10 MiB, so a
      # client draining this feed paid the conversation's whole attachment
      # history once per page.
      [first | _] =
        for i <- 1..4 do
          {turn, start} = turn_with_start(conv, %{prompt: "prompt #{i}"})
          with_image(turn)
          start
        end

      watch_turn_reads()

      blocks = blocks_by_id(conn, key, conv, "?blocks=true&prompts=true&limit=1")

      # The prompt still renders, so this is a bounded read and not a skipped one.
      assert blocks[first.id] == [%{"kind" => "prompt", "body" => "prompt 1"}]

      # One query, and it returned the page's single turn rather than all four.
      # `turn_images` is absent entirely: no image byte is read to render text.
      assert turn_reads() == [{"turns", 1}]
    end

    test "a request that cannot render a prompt never reaches the turns table", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      {turn, start} = turn_with_start(conv, %{prompt: "hello"})
      with_image(turn)
      provision = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      watch_turn_reads()

      # Documented as ignored: `blocks=true` is what renders a prompt.
      assert conn |> get_events(key, conv, "?prompts=true") |> json_response(200)

      # The stream filter drops every stage event, so no anchor reaches the page.
      assert conn
             |> get_events(key, conv, "?blocks=true&prompts=true&streams=acp")
             |> json_response(200)

      # A drained cursor: nothing left to hydrate.
      assert conn
             |> get_events(key, conv, "?blocks=true&prompts=true&after=#{provision.id}")
             |> json_response(200)

      # A page with events but no turn start on it.
      assert conn
             |> get_events(key, conv, "?blocks=true&prompts=true&limit=1&after=#{start.id}")
             |> json_response(200)

      assert turn_reads() == []
    end
  end

  describe "pagination" do
    test "pages through the feed with next_cursor", %{conn: conn, key: key, conv: conv} do
      events = for i <- 1..5, do: insert_log_event(conv, data: "line #{i}")
      ids = Enum.map(events, & &1.id)

      page1 = conn |> get_events(key, conv, "?limit=2") |> json_response(200)
      assert Enum.map(page1["data"], & &1["id"]) == Enum.take(ids, 2)
      assert page1["meta"]["has_more"]
      assert page1["meta"]["next_cursor"] == Enum.at(ids, 1)

      page2 =
        conn
        |> get_events(key, conv, "?limit=2&after=#{page1["meta"]["next_cursor"]}")
        |> json_response(200)

      assert Enum.map(page2["data"], & &1["id"]) == Enum.slice(ids, 2, 2)
      assert page2["meta"]["has_more"]

      page3 =
        conn
        |> get_events(key, conv, "?limit=2&after=#{page2["meta"]["next_cursor"]}")
        |> json_response(200)

      assert Enum.map(page3["data"], & &1["id"]) == [List.last(ids)]

      # The last page must say so — a client that keeps following has_more
      # would loop forever on a finished conversation.
      refute page3["meta"]["has_more"]
    end

    test "the limit is capped so a huge feed cannot be pulled in one request", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      insert_log_event(conv)

      body = conn |> get_events(key, conv, "?limit=99999") |> json_response(200)
      assert body["meta"]["limit"] == 1000
    end

    test "a zero or negative limit clamps to one page of one", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      insert_log_event(conv)

      assert conn
             |> get_events(key, conv, "?limit=0")
             |> json_response(200)
             |> get_in([
               "meta",
               "limit"
             ]) == 1

      assert conn
             |> get_events(key, conv, "?limit=-5")
             |> json_response(200)
             |> get_in([
               "meta",
               "limit"
             ]) == 1
    end

    test "a non-numeric limit is refused by the spec", %{conn: conn, key: key, conv: conv} do
      conn |> get_events(key, conv, "?limit=abc") |> json_response(422)
    end

    test "has_more accounts for the stream filter, not just the raw feed", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # Two stdout rows either side of noise: paging over a filtered feed must
      # not report more pages because of rows the filter removed.
      a = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")
      insert_log_event(conv, kind: "output", stream: "stderr", data: "noise")
      b = insert_log_event(conv, kind: "output", stream: "stdout", data: "b")

      body = conn |> get_events(key, conv, "?streams=stdout&limit=2") |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [a.id, b.id]
      refute body["meta"]["has_more"]
    end
  end

  describe "order=desc (#2531)" do
    defp page_ids(body), do: Enum.map(body["data"], & &1["id"])

    defp turn_events(conv, n, overrides \\ %{}) do
      turn = insert_turn(conv, overrides)

      start =
        insert_log_event(conv,
          kind: "stage",
          stream: "",
          stage: "turn",
          state: "started",
          turn_id: turn.id,
          data: Jason.encode!(%{turn_id: turn.id})
        )

      rest = for i <- 2..n//1, do: insert_log_event(conv, turn_id: turn.id, data: "line #{i}")
      {turn, [start | rest]}
    end

    test "pages backward newest first with oldest, newest and next cursors", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      ids = for(i <- 1..5, do: insert_log_event(conv, data: "line #{i}")) |> Enum.map(& &1.id)

      first = conn |> get_events(key, conv, "?order=desc&limit=2") |> json_response(200)
      assert page_ids(first) == [Enum.at(ids, 4), Enum.at(ids, 3)]

      assert %{"has_more" => true, "next_cursor" => next} = first["meta"]

      assert %{
               "order" => "desc",
               "oldest_cursor" => ^next,
               "newest_cursor" => newest,
               "turn_split" => false
             } = first["page"]

      assert next == Enum.at(ids, 3)
      # The SSE follow starts from the newest event of the first page.
      assert newest == List.last(ids)

      second =
        conn |> get_events(key, conv, "?order=desc&limit=2&before=#{next}") |> json_response(200)

      assert page_ids(second) == [Enum.at(ids, 2), Enum.at(ids, 1)]

      last =
        conn
        |> get_events(key, conv, "?order=desc&limit=2&before=#{second["meta"]["next_cursor"]}")
        |> json_response(200)

      assert page_ids(last) == [hd(ids)]
      refute last["meta"]["has_more"]
    end

    test "whole_turns returns complete newest turns, then earlier ones", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      setup_event = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")
      {_a, a_events} = turn_events(conv, 4)
      {_b, b_events} = turn_events(conv, 3)

      newest =
        conn
        |> get_events(key, conv, "?order=desc&limit=2&whole_turns=true")
        |> json_response(200)

      # Past limit, down to turn B's first event.
      assert page_ids(newest) == b_events |> Enum.map(& &1.id) |> Enum.reverse()
      assert newest["meta"]["limit"] == 2
      assert newest["meta"]["has_more"]

      older =
        conn
        |> get_events(
          key,
          conv,
          "?order=desc&limit=2&whole_turns=true&before=#{newest["meta"]["next_cursor"]}"
        )
        |> json_response(200)

      assert page_ids(older) == a_events |> Enum.map(& &1.id) |> Enum.reverse()

      rest =
        conn
        |> get_events(
          key,
          conv,
          "?order=desc&limit=2&whole_turns=true&before=#{older["meta"]["next_cursor"]}"
        )
        |> json_response(200)

      assert page_ids(rest) == [setup_event.id]
      refute rest["meta"]["has_more"]
    end

    test "prompts and blocks render on a backward page", %{conn: conn, key: key, conv: conv} do
      {_a, [a_start | _]} = turn_events(conv, 3, %{prompt: "first question"})
      {_b, [b_start | _]} = turn_events(conv, 3, %{prompt: "second question"})

      body =
        conn
        |> get_events(key, conv, "?order=desc&limit=1&whole_turns=true&blocks=true&prompts=true")
        |> json_response(200)

      blocks = Map.new(body["data"], &{&1["id"], &1["blocks"]})
      assert blocks[b_start.id] == [%{"kind" => "prompt", "body" => "second question"}]
      refute Map.has_key?(blocks, a_start.id)

      older =
        conn
        |> get_events(
          key,
          conv,
          "?order=desc&limit=1&whole_turns=true&blocks=true&prompts=true" <>
            "&before=#{body["meta"]["next_cursor"]}"
        )
        |> json_response(200)

      assert Map.new(older["data"], &{&1["id"], &1["blocks"]})[a_start.id] ==
               [%{"kind" => "prompt", "body" => "first question"}]
    end

    test "the stream filter applies to backward pages", %{conn: conn, key: key, conv: conv} do
      a = insert_log_event(conv, stream: "stdout", data: "a")
      insert_log_event(conv, stream: "stderr", data: "noise")
      b = insert_log_event(conv, stream: "stdout", data: "b")

      body =
        conn |> get_events(key, conv, "?order=desc&streams=stdout&limit=2") |> json_response(200)

      assert page_ids(body) == [b.id, a.id]
      refute body["meta"]["has_more"]
    end

    test "whole_turns without order=desc is refused", %{conn: conn, key: key, conv: conv} do
      assert %{"error" => "invalid_parameters"} =
               conn |> get_events(key, conv, "?whole_turns=true") |> json_response(422)
    end

    test "an unknown order is refused by the spec", %{conn: conn, key: key, conv: conv} do
      conn |> get_events(key, conv, "?order=newest") |> json_response(422)
    end

    test "another tenant's conversation is 404 backward too", %{conn: conn, key: key} do
      other_conv = insert_conversation(user_id: insert_verified_user().id)
      insert_log_event(other_conv, data: "secret output")

      conn =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{other_conv.id}/events?order=desc&whole_turns=true")

      assert json_response(conn, 404)
      refute conn.resp_body =~ "secret output"
    end

    test "forward paging is unchanged, and reports its order", %{conn: conn, key: key, conv: conv} do
      ids = for(i <- 1..3, do: insert_log_event(conv, data: "line #{i}")) |> Enum.map(& &1.id)

      body = conn |> get_events(key, conv, "?limit=2") |> json_response(200)
      assert page_ids(body) == Enum.take(ids, 2)

      assert %{"has_more" => true, "next_cursor" => next} = body["meta"]

      assert %{
               "order" => "asc",
               "oldest_cursor" => oldest,
               "newest_cursor" => ^next,
               "turn_split" => false
             } = body["page"]

      assert next == Enum.at(ids, 1)
      assert oldest == hd(ids)
    end

    test "before bounds a forward page from above", %{conn: conn, key: key, conv: conv} do
      ids = for(i <- 1..4, do: insert_log_event(conv, data: "line #{i}")) |> Enum.map(& &1.id)

      body =
        conn
        |> get_events(key, conv, "?after=#{hd(ids)}&before=#{List.last(ids)}")
        |> json_response(200)

      assert page_ids(body) == Enum.slice(ids, 1, 2)
      refute body["meta"]["has_more"]
    end

    test "a 7,000-event conversation opens at its newest complete turns in one request", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      now = DateTime.utc_now()
      turns = for _ <- 1..70, do: insert_turn(conv)

      rows =
        for turn <- turns, i <- 1..100 do
          %{
            conversation_id: conv.id,
            turn_id: turn.id,
            kind: if(i == 1, do: "stage", else: "output"),
            stream: if(i == 1, do: "", else: "stdout"),
            stage: if(i == 1, do: "turn", else: ""),
            state: if(i == 1, do: "started", else: ""),
            data: "line #{i}",
            inserted_at: now
          }
        end

      for chunk <- Enum.chunk_every(rows, 1000),
          do: Fountain.Repo.insert_all(Fountain.Conversations.LogEvent, chunk)

      {micros, body} =
        :timer.tc(fn ->
          conn
          |> get_events(
            key,
            conv,
            "?order=desc&limit=150&whole_turns=true&blocks=true&prompts=true"
          )
          |> json_response(200)
        end)

      # Two complete turns, each opening on its prompt-bearing start event.
      assert length(body["data"]) == 200
      starts = Enum.filter(body["data"], &(&1["stage"] == "turn"))
      assert Enum.map(starts, & &1["turn_id"]) == [Enum.at(turns, -1).id, Enum.at(turns, -2).id]
      assert Enum.all?(starts, &match?([%{"kind" => "prompt"}], &1["blocks"]))

      # The earlier turns follow without re-reading the loaded tail.
      older =
        conn
        |> get_events(
          key,
          conv,
          "?order=desc&limit=150&whole_turns=true&before=#{body["meta"]["next_cursor"]}"
        )
        |> json_response(200)

      assert List.first(older["data"])["id"] < body["page"]["oldest_cursor"]
      assert length(older["data"]) == 200

      if System.get_env("FOUNTAIN_BENCH"),
        do:
          IO.puts(
            "\n7,000 events over HTTP, newest complete turns: 1 request, #{div(micros, 1000)} ms"
          )
    end
  end

  describe "tenant scoping" do
    test "another tenant's conversation is 404, not 403", %{conn: conn, key: key} do
      other = insert_verified_user()
      other_conv = insert_conversation(user_id: other.id)
      insert_log_event(other_conv, data: "secret output")

      conn =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{other_conv.id}/events")

      assert json_response(conn, 404)
      refute conn.resp_body =~ "secret output"
    end

    test "requires authentication", %{conn: conn, conv: conv} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/conversations/#{conv.id}/events")
      |> json_response(401)
    end
  end
end
