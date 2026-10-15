defmodule FountainWeb.SseStreamTest do
  @moduledoc """
  The SSE loop itself: replay from `Last-Event-ID`, the live PubSub tail, the
  `?streams=` filter, heartbeats, and the idle exit.

  None of it was tested. The endpoint had coverage for "does it return 200",
  which is how a blanket 406 shipped (#201) and how #196's silent mid-turn exit
  went unnoticed — the loop is the part that carries every CLI user's output and
  the dashboard log viewer.

  The timings are the behaviour here, and waiting 15s for a heartbeat and 60s
  for the idle exit is why this was never covered. Both are now read from
  application env, so these drive the real loop at milliseconds.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]

  @endpoint FountainWeb.Endpoint

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    conv = insert_conversation(user_id: user.id)

    previous = {
      Application.get_env(:fountain, :sse_heartbeat_ms),
      Application.get_env(:fountain, :sse_idle_timeout_ms)
    }

    on_exit(fn ->
      {hb, idle} = previous

      if hb,
        do: Application.put_env(:fountain, :sse_heartbeat_ms, hb),
        else: Application.delete_env(:fountain, :sse_heartbeat_ms)

      if idle,
        do: Application.put_env(:fountain, :sse_idle_timeout_ms, idle),
        else: Application.delete_env(:fountain, :sse_idle_timeout_ms)
    end)

    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    {:ok, user: user, raw_key: raw_key, conv: conv}
  end

  defp fast_loop(heartbeat_ms, idle_ms) do
    Application.put_env(:fountain, :sse_heartbeat_ms, heartbeat_ms)
    Application.put_env(:fountain, :sse_idle_timeout_ms, idle_ms)
  end

  # Writes the row and puts it on the topic, which is what ConversationServer
  # and Provisioning do — Conversations.log!/1 only persists, so a test using it
  # alone would silently exercise nothing.
  defp publish(conv, attrs) do
    ev = insert_log_event(conv, attrs)
    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, ev})
    ev
  end

  defp stream(raw_key, path, headers \\ []) do
    conn =
      Enum.reduce(headers, authed_with_key(build_conn(), raw_key), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    Phoenix.ConnTest.dispatch(conn, @endpoint, :get, path)
  end

  describe "replay" do
    test "history and replay retain the timestamp supplied to live broadcasts (#1624)", %{
      raw_key: key,
      conv: conv
    } do
      timestamp = ~U[2026-09-06 01:30:46.094866Z]

      event =
        Fountain.Conversations.log!(%{
          conversation_id: conv.id,
          kind: "output",
          stream: "stdout",
          data: "precision fixture",
          inserted_at: timestamp
        })

      replay = stream(key, "/api/conversations/#{conv.id}/stream?wait=false")

      payload =
        replay.resp_body
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "data: "))
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()

      feed =
        stream(key, "/api/conversations/#{conv.id}/events") |> Phoenix.ConnTest.json_response(200)

      assert [%{"id" => id, "ts" => ts}] = feed["data"]
      assert id == event.id
      assert ts == DateTime.to_iso8601(event.inserted_at)
      assert payload["ts"] == ts
    end

    test "drains buffered events and closes with wait=false", %{raw_key: key, conv: conv} do
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "first"})
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "second"})

      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert conn.resp_body =~ "first"
      assert conn.resp_body =~ "second"
    end

    test "Last-Event-ID replays only what came after it", %{raw_key: key, conv: conv} do
      first = insert_log_event(conv, %{kind: "output", stream: "stdout", data: "already-seen"})
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "missed-this"})

      conn =
        stream(key, "/api/conversations/#{conv.id}/stream?wait=false", [
          {"last-event-id", to_string(first.id)}
        ])

      # The point of the header: a client that reconnects must not be handed
      # output it already printed.
      refute conn.resp_body =~ "already-seen"
      assert conn.resp_body =~ "missed-this"
    end

    test "events carry an id, so a client can resume from them", %{raw_key: key, conv: conv} do
      ev = insert_log_event(conv, %{kind: "output", stream: "stdout", data: "x"})

      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.resp_body =~ "id: #{ev.id}"
    end

    test "an output event streams state and stage as null, not \"\" (#1430)", %{
      raw_key: key,
      conv: conv
    } do
      # The stream builds its own payload rather than sharing the JSON view's,
      # so it is a second place the conversion has to happen. A reader of the
      # SSE feed and a reader of `/events` must not disagree about what "no
      # state" looks like.
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "x"})

      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.resp_body =~ ~s("state":null)
      assert conn.resp_body =~ ~s("stage":null)
      refute conn.resp_body =~ ~s("state":"")
      refute conn.resp_body =~ ~s("stage":"")
    end

    test "a garbage Last-Event-ID replays everything rather than nothing", %{
      raw_key: key,
      conv: conv
    } do
      # Falling back to "send nothing" would lose output silently, which is the
      # worse direction to be wrong in.
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "keep-me"})

      conn =
        stream(key, "/api/conversations/#{conv.id}/stream?wait=false", [
          {"last-event-id", "not-a-number"}
        ])

      assert conn.resp_body =~ "keep-me"
    end
  end

  describe "the streams filter" do
    setup %{conv: conv} do
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "on-stdout"})
      insert_log_event(conv, %{kind: "output", stream: "stderr", data: "on-stderr"})
      insert_log_event(conv, %{kind: "output", stream: "acp", data: "on-acp"})
      insert_log_event(conv, %{kind: "stage", stream: "", stage: "provision", state: "done"})
      :ok
    end

    test "no filter sends everything", %{raw_key: key, conv: conv} do
      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.resp_body =~ "on-stdout"
      assert conn.resp_body =~ "on-stderr"
      assert conn.resp_body =~ "event: stage"
    end

    test "a single stream excludes the others", %{raw_key: key, conv: conv} do
      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false&streams=stdout")

      assert conn.resp_body =~ "on-stdout"
      refute conn.resp_body =~ "on-stderr"
      refute conn.resp_body =~ "event: stage"
    end

    test "several streams can be combined", %{raw_key: key, conv: conv} do
      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false&streams=stderr,stage")

      refute conn.resp_body =~ "on-stdout"
      assert conn.resp_body =~ "on-stderr"
      assert conn.resp_body =~ "event: stage"
    end

    # These three existed for stdout/stderr/stage, which is exactly why the
    # `acp` stream could be dropped from every filtered replay without a test
    # noticing. `managoat acp` asks for `acp,stage` on every reconnect and
    # `acp` alone on every `session/load`.
    test "the acp stream replays when asked for by name", %{raw_key: key, conv: conv} do
      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false&streams=acp")

      assert conn.resp_body =~ "on-acp"
      refute conn.resp_body =~ "on-stdout"
      refute conn.resp_body =~ "event: stage"
    end

    test "acp combines with stage, which is what a protocol client asks for", %{
      raw_key: key,
      conv: conv
    } do
      conn = stream(key, "/api/conversations/#{conv.id}/stream?wait=false&streams=acp,stage")

      assert conn.resp_body =~ "on-acp"
      assert conn.resp_body =~ "event: stage"
      refute conn.resp_body =~ "on-stdout"
    end
  end

  describe "the live tail" do
    test "an event published while connected is streamed", %{raw_key: key, conv: conv} do
      # The request has to run in its own process: the loop blocks on `receive`,
      # so the broadcast has to come from somewhere else.
      fast_loop(60_000, 600)

      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())
          stream(key, "/api/conversations/#{conv.id}/stream")
        end)

      # Give the loop time to subscribe before publishing.
      Process.sleep(300)

      timestamp = ~U[2026-09-06 01:30:46.987654Z]

      event =
        publish(conv, %{
          kind: "output",
          stream: "stdout",
          data: "live-event",
          inserted_at: timestamp
        })

      conn = Task.await(task, 5_000)

      assert conn.status == 200
      assert conn.resp_body =~ "live-event"
      assert conn.resp_body =~ ~s("ts":"#{DateTime.to_iso8601(timestamp)}")

      feed =
        stream(key, "/api/conversations/#{conv.id}/events") |> Phoenix.ConnTest.json_response(200)

      assert [%{"id" => id, "ts" => ts}] = feed["data"]
      assert id == event.id
      assert ts == DateTime.to_iso8601(timestamp)
    end

    test "a filtered-out live event is not streamed", %{raw_key: key, conv: conv} do
      fast_loop(60_000, 600)

      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())
          stream(key, "/api/conversations/#{conv.id}/stream?streams=stdout")
        end)

      Process.sleep(300)

      publish(conv, %{kind: "output", stream: "stderr", data: "filtered-out"})
      publish(conv, %{kind: "output", stream: "stdout", data: "wanted"})

      conn = Task.await(task, 5_000)

      assert conn.resp_body =~ "wanted"
      refute conn.resp_body =~ "filtered-out"
    end
  end

  describe "heartbeats and the idle exit" do
    test "a quiet stream closes so the client can reconnect", %{raw_key: key, conv: conv} do
      # Heartbeat set beyond the test's life so none arrives: this exercises the
      # `after` clause on its own.
      fast_loop(60_000, 250)

      started = System.monotonic_time(:millisecond)
      conn = stream(key, "/api/conversations/#{conv.id}/stream")
      elapsed = System.monotonic_time(:millisecond) - started

      assert conn.status == 200
      refute conn.resp_body =~ "heartbeat"
      assert elapsed < 3_000, "the idle timeout did not fire (took #{elapsed}ms)"
    end

    defmodule HeartbeatAdapter do
      @moduledoc false

      defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
      defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
      defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
      defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
      defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
      defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
      defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn

      def chunk(state, body) do
        send(state.observer, {:heartbeat_chunk, self(), IO.iodata_to_binary(body)})

        if Map.get(state, :pause, false) do
          receive do
            :continue_heartbeat -> :ok
          after
            5_000 -> raise "test did not acknowledge the heartbeat"
          end
        end

        if state.remaining == 0 do
          {:error, :closed}
        else
          Plug.Adapters.Test.Conn.chunk(%{state | remaining: state.remaining - 1}, body)
        end
      end
    end

    defmodule HeartbeatEndpoint do
      @moduledoc false

      defdelegate init(opts), to: FountainWeb.Endpoint

      def call(conn, opts) do
        {Plug.Adapters.Test.Conn, state} = conn.adapter
        state = Map.merge(state, conn.private.heartbeat_adapter)
        FountainWeb.Endpoint.call(%{conn | adapter: {HeartbeatAdapter, state}}, opts)
      end
    end

    defp heartbeat_stream(key, conv, pause) do
      parent = self()

      Task.async(fn ->
        if pause, do: send(self(), :heartbeat)

        build_conn()
        |> authed_with_key(key)
        |> Plug.Conn.put_private(:heartbeat_adapter, %{
          observer: parent,
          remaining: 2,
          pause: pause
        })
        |> Phoenix.ConnTest.dispatch(
          HeartbeatEndpoint,
          :get,
          "/api/conversations/#{conv.id}/stream"
        )
      end)
    end

    test "heartbeats are written and rescheduled until the client disconnects", %{
      raw_key: key,
      conv: conv
    } do
      # Observe actual heartbeat writes instead of racing a 200 ms idle window
      # against a loaded scheduler. The quiet-stream test above covers expiry;
      # here only a failed chunk can end the loop. A missing reschedule fails
      # the bounded await, and the adapter closes after two successful writes.
      fast_loop(1, :infinity)
      task = heartbeat_stream(key, conv, false)

      try do
        conn = Task.await(task, 5_000)
        pid = task.pid

        for _ <- 1..3 do
          assert_receive {:heartbeat_chunk, ^pid, ": heartbeat\n\n"}
        end

        assert conn.status == 200
        assert conn.resp_body == String.duplicate(": heartbeat\n\n", 2)
      after
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "queued heartbeats keep the stream open even with a zero idle window", %{
      raw_key: key,
      conv: conv
    } do
      # Drive delivery explicitly here, independently of the real-timer test
      # above. Zero makes every idle window expired already, so only consuming
      # the queued heartbeat before considering idle expiry keeps it open.
      fast_loop(60_000, 0)
      task = heartbeat_stream(key, conv, true)

      try do
        pid = task.pid

        for _ <- 1..3 do
          assert_receive {:heartbeat_chunk, ^pid, ": heartbeat\n\n"}, 5_000
          # Both sends come from this process, preserving mailbox order.
          send(pid, :heartbeat)
          send(pid, :continue_heartbeat)
        end

        conn = Task.await(task, 5_000)
        assert conn.status == 200
        assert conn.resp_body == String.duplicate(": heartbeat\n\n", 2)
      after
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  describe "conversation server death" do
    # Before the stream monitored the server, every death that skipped the
    # explicit :terminate_conv path — a crash, a deploy —
    # left the topic silent while the heartbeat kept the connection alive:
    # the client received heartbeats forever with no data, no terminal event
    # and no disconnect to trigger a reconnect.
    defp fake_server(conv_id) do
      test_pid = self()

      pid =
        spawn(fn ->
          Registry.register(Fountain.ConversationRegistry, conv_id, nil)
          send(test_pid, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered, 2_000
      pid
    end

    test "a crashing server ends the stream with a synthetic failed stage", %{
      raw_key: key,
      conv: conv
    } do
      # Idle timeout far beyond the await below: only the :DOWN can close it.
      fast_loop(60_000, 60_000)

      server = fake_server(conv.id)
      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())
          stream(key, "/api/conversations/#{conv.id}/stream")
        end)

      # Give the loop time to subscribe and monitor before the kill.
      Process.sleep(300)
      Process.exit(server, :kill)

      conn = Task.await(task, 5_000)

      assert conn.status == 200
      assert conn.resp_body =~ ~s("stage":"server")
      assert conn.resp_body =~ ~s("state":"failed")

      # #2297: this synthetic frame is the one write_event/2 never builds —
      # it must still match the schema the operation declares. `stream` is
      # `""` here, not null: StreamLogEvent has no `nullable: true` on it,
      # matching every persisted event (the domain schema defaults an empty
      # stream to `""`, never nil).
      [payload] =
        Regex.run(~r/data: (\{[^\n]*"stage":"server"[^\n]*\})/, conn.resp_body,
          capture: :all_but_first
        )

      decoded = Jason.decode!(payload)

      assert FountainWeb.SchemaGuard.validate_value(FountainWeb.Schemas.StreamLogEvent, decoded) ==
               :ok
    end

    test "a clean shutdown reads as the server stage reaching done", %{
      raw_key: key,
      conv: conv
    } do
      fast_loop(60_000, 60_000)

      server = fake_server(conv.id)
      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())
          stream(key, "/api/conversations/#{conv.id}/stream")
        end)

      Process.sleep(300)
      Process.exit(server, :shutdown)

      conn = Task.await(task, 5_000)

      assert conn.resp_body =~ ~s("stage":"server")
      assert conn.resp_body =~ ~s("state":"done")
    end

    test "a synthetic terminal event carries no SSE id, preserving resume", %{
      raw_key: key,
      conv: conv
    } do
      # Resuming from a synthetic id would skip real events; the reconnect
      # must replay from the last PERSISTED event the client saw.
      fast_loop(60_000, 60_000)

      server = fake_server(conv.id)
      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())
          stream(key, "/api/conversations/#{conv.id}/stream")
        end)

      Process.sleep(300)
      Process.exit(server, :kill)
      conn = Task.await(task, 5_000)

      [chunk] =
        conn.resp_body
        |> String.split("\n\n", trim: true)
        |> Enum.filter(&(&1 =~ ~s("stage":"server")))

      refute chunk =~ ~r/^id: /m
    end
  end
end
