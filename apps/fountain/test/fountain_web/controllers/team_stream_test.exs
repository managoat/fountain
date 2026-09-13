defmodule FountainWeb.TeamStreamTest do
  @moduledoc """
  `GET /api/team/stream`: every teammate's events on one connection, labelled
  with the conversation and agent, plus the `team` event and follow-on
  subscription when the roster changes. Same fast-loop technique as
  `SseStreamTest`.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.ConnTest, only: [build_conn: 0]

  alias Fountain.Team

  @endpoint FountainWeb.Endpoint

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)

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

    Application.put_env(:fountain, :sse_heartbeat_ms, 60_000)
    Application.put_env(:fountain, :sse_idle_timeout_ms, 800)

    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    {:ok, user: user, raw_key: raw_key}
  end

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp publish(conv, attrs) do
    ev = insert_log_event(conv, attrs)
    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, ev})
    ev
  end

  defp stream_async(raw_key, headers \\ [], path \\ "/api/team/stream") do
    parent = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())

      conn =
        Enum.reduce(headers, authed_with_key(build_conn(), raw_key), fn {k, v}, c ->
          Plug.Conn.put_req_header(c, k, v)
        end)

      Phoenix.ConnTest.dispatch(conn, @endpoint, :get, path)
    end)
  end

  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  defp stream_ready(raw_key) do
    parent = self()

    Mimic.stub(Plug.Adapters.Test.Conn, :chunk, fn state, body ->
      result = Mimic.call_original(Plug.Adapters.Test.Conn, :chunk, [state, body])

      if body in [": connected\n\n", "event: team\ndata: {\"reason\":\"changed\"}\n\n"] do
        # Both frames are written after follow_team has subscribed. Hold the
        # stream here so fixture work cannot consume its 800 ms idle window.
        ref = make_ref()
        send(parent, {:stream_ready, self(), body, ref})
        assert_receive {:continue_stream, ^ref}, 5_000
      end

      result
    end)

    # No Last-Event-ID: the queued broadcasts must reach the live loop, since
    # replay is skipped for this connection.
    task = stream_async(raw_key)

    on_exit(fn ->
      ref = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end)

    {task, await_ready(task, ": connected\n\n")}
  end

  defp await_ready(task, body) do
    pid = task.pid
    assert_receive {:stream_ready, ^pid, ^body, ref}, 5_000
    ref
  end

  defp continue_stream(task, ref), do: send(task.pid, {:continue_stream, ref})

  test "events from every teammate arrive on one connection, labelled", %{
    user: user,
    raw_key: key
  } do
    ada = insert_agent(user_id: user.id, name: "Ada")
    linus = insert_agent(user_id: user.id, name: "Linus")
    ada_conv = insert_teammate_conv(user, ada)
    linus_conv = insert_teammate_conv(user, linus)
    # Not on the team: must not be streamed.
    other_conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {task, ready} = stream_ready(key)

    publish(ada_conv, %{kind: "output", stream: "acp", data: "from-ada"})
    publish(linus_conv, %{kind: "output", stream: "acp", data: "from-linus"})
    publish(other_conv, %{kind: "output", stream: "acp", data: "not-on-team"})

    continue_stream(task, ready)
    conn = Task.await(task, 5_000)
    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    body = conn.resp_body
    assert body =~ "from-ada"
    assert body =~ "from-linus"
    refute body =~ "not-on-team"

    # Each payload names its conversation and agent so a client can route it.
    [ada_payload] = Regex.run(~r/data: (\{[^\n]*from-ada[^\n]*\})/, body, capture: :all_but_first)
    decoded = Jason.decode!(ada_payload)
    assert decoded["conversation_id"] == ada_conv.id
    assert decoded["agent_id"] == ada.id
    assert decoded["kind"] == "output"
  end

  test "the first byte is a comment, sent before any event or heartbeat", %{
    user: user,
    raw_key: key
  } do
    insert_teammate_conv(user, insert_agent(user_id: user.id))
    conn = stream_async(key) |> Task.await(5_000)
    assert String.starts_with?(conn.resp_body, ": connected\n\n")
  end

  test "Last-Event-ID replays what was missed across the team", %{user: user, raw_key: key} do
    ada = insert_agent(user_id: user.id, name: "Ada")
    linus = insert_agent(user_id: user.id, name: "Linus")
    ada_conv = insert_teammate_conv(user, ada)
    linus_conv = insert_teammate_conv(user, linus)

    seen = insert_log_event(ada_conv, %{kind: "output", stream: "acp", data: "already-seen"})
    insert_log_event(linus_conv, %{kind: "output", stream: "acp", data: "missed-linus"})
    insert_log_event(ada_conv, %{kind: "output", stream: "acp", data: "missed-ada"})

    conn = stream_async(key, [{"last-event-id", to_string(seen.id)}]) |> Task.await(5_000)

    refute conn.resp_body =~ "already-seen"
    assert conn.resp_body =~ "missed-linus"
    assert conn.resp_body =~ "missed-ada"
  end

  test "a roster change sends a `team` event and follows the new conversation", %{
    user: user,
    raw_key: key
  } do
    ada = insert_agent(user_id: user.id, name: "Ada")
    insert_teammate_conv(user, ada)
    linus = insert_agent(user_id: user.id, name: "Linus")

    {task, ready} = stream_ready(key)

    # Linus joins after the stream connected: the roster broadcast makes the
    # stream re-list and subscribe, so his first event still arrives.
    linus_conv = insert_teammate_conv(user, linus)
    Phoenix.PubSub.broadcast(Fountain.PubSub, "team:#{user.id}", {:team_changed, user.id})
    continue_stream(task, ready)
    followed = await_ready(task, "event: team\ndata: {\"reason\":\"changed\"}\n\n")
    publish(linus_conv, %{kind: "output", stream: "acp", data: "from-new-linus"})

    continue_stream(task, followed)
    conn = Task.await(task, 5_000)
    assert conn.resp_body =~ "event: team\ndata: {\"reason\":\"changed\"}"
    assert conn.resp_body =~ "from-new-linus"
  end

  test "a schedule change sends a `schedule` event (#825)", %{user: user, raw_key: key} do
    ada = insert_agent(user_id: user.id, name: "Ada")
    insert_teammate_conv(user, ada)

    task = stream_async(key)
    Process.sleep(300)

    {:ok, _} =
      Fountain.Team.Schedules.create_schedule(user.id, %{
        "agent_id" => ada.id,
        "cron" => "0 9 * * *",
        "prompt" => "standup"
      })

    conn = Task.await(task, 5_000)
    assert conn.resp_body =~ "event: schedule\ndata: {\"reason\":\"changed\"}"
  end

  test "a runner connecting or dropping sends a `team` event (#834)", %{user: user, raw_key: key} do
    ada = insert_agent(user_id: user.id, name: "Ada")
    insert_teammate_conv(user, ada)
    {:ok, runner} = Fountain.Runners.register(user.id, %{"name" => "mini"})

    task = stream_async(key)
    Process.sleep(300)

    {:ok, daemon} =
      Managoat.Runner.FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")

    Process.sleep(100)
    Managoat.Runner.FakeDaemon.stop(daemon)

    conn = Task.await(task, 5_000)
    assert conn.resp_body =~ "event: team\ndata: {\"reason\":\"changed\"}"
  end

  test "Team.add_teammate and remove_teammate broadcast the roster change", %{user: user} do
    Team.subscribe(user.id)
    ada = insert_agent(user_id: user.id, name: "Ada")
    insert_teammate_conv(user, ada)

    :ok = Team.remove_teammate(user.id, ada.id)
    assert_receive {:team_changed, _}
  end

  test "the streams filter applies to replay and to the live tail", %{user: user, raw_key: key} do
    ada = insert_agent(user_id: user.id, name: "Ada")
    conv = insert_teammate_conv(user, ada)
    marker = insert_log_event(conv, %{kind: "output", stream: "stdout", data: "before"})
    insert_log_event(conv, %{kind: "output", stream: "stdout", data: "replayed-stdout"})
    insert_log_event(conv, %{kind: "output", stream: "acp", data: "replayed-acp"})

    parent = self()

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())

        build_conn()
        |> authed_with_key(key)
        |> Plug.Conn.put_req_header("last-event-id", to_string(marker.id))
        |> Phoenix.ConnTest.dispatch(@endpoint, :get, "/api/team/stream?streams=acp")
      end)

    Process.sleep(300)
    publish(conv, %{kind: "output", stream: "stdout", data: "live-stdout"})
    publish(conv, %{kind: "output", stream: "acp", data: "live-acp"})

    conn = Task.await(task, 5_000)
    assert conn.resp_body =~ "replayed-acp"
    assert conn.resp_body =~ "live-acp"
    refute conn.resp_body =~ "replayed-stdout"
    refute conn.resp_body =~ "live-stdout"
    refute conn.resp_body =~ "before"
  end

  # #881: this stream is the one a team UI actually opens, and it was the only
  # feed that could not hand back server-parsed blocks. Without them a client
  # either re-parses the runtime's own dialect or opens a second connection per
  # thread for detail, which is exactly what `?blocks=true` exists to prevent.
  describe "?blocks=true (#881)" do
    test "adds the server-parsed blocks per event, in replay and in the live tail", %{
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, %{runtime: "claude"})
      marker = insert_log_event(conv, %{kind: "output", stream: "acp", data: "m"})
      insert_log_event(conv, %{kind: "output", stream: "acp", data: acp_text("replayed")})

      task =
        stream_async(
          key,
          [{"last-event-id", to_string(marker.id)}],
          "/api/team/stream?blocks=true"
        )

      Process.sleep(300)
      publish(conv, %{kind: "output", stream: "acp", data: acp_text("live")})

      body = Task.await(task, 5_000).resp_body

      for text <- ["replayed", "live"] do
        [payload] =
          Regex.run(~r/data: (\{[^\n]*#{text}[^\n]*\})/, body, capture: :all_but_first)

        decoded = Jason.decode!(payload)
        assert %{"blocks" => [%{"kind" => "text", "body" => ^text}]} = decoded
        # Still labelled, so a client can route it to a roster row.
        assert decoded["agent_id"] == ada.id
      end
    end

    test "the runtime comes from the conversation that produced the event, not the request", %{
      user: user,
      raw_key: key
    } do
      # The whole complication of this stream: it is multi-conversation, so
      # there is no single runtime to parse against.
      claude = insert_agent(user_id: user.id, name: "Ada", runtime: "claude")
      other = insert_agent(user_id: user.id, name: "Linus", runtime: "codex")
      claude_conv = insert_teammate_conv(user, claude, %{runtime: "claude"})
      other_conv = insert_teammate_conv(user, other, %{runtime: "codex"})

      task = stream_async(key, [], "/api/team/stream?blocks=true")
      Process.sleep(300)
      publish(claude_conv, %{kind: "output", stream: "acp", data: acp_text("from-claude")})
      publish(other_conv, %{kind: "output", stream: "acp", data: acp_text("from-codex")})

      body = Task.await(task, 5_000).resp_body

      for text <- ["from-claude", "from-codex"] do
        [payload] =
          Regex.run(~r/data: (\{[^\n]*#{text}[^\n]*\})/, body, capture: :all_but_first)

        assert %{"blocks" => [%{"kind" => "text", "body" => ^text}]} = Jason.decode!(payload)
      end
    end

    test "without the flag the field is absent, so existing clients see the same payload", %{
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, %{runtime: "claude"})

      task = stream_async(key)
      Process.sleep(300)
      publish(conv, %{kind: "output", stream: "acp", data: acp_text("plain")})

      [payload] =
        Regex.run(
          ~r/data: (\{[^\n]*plain[^\n]*\})/,
          Task.await(task, 5_000).resp_body,
          capture: :all_but_first
        )

      refute Map.has_key?(Jason.decode!(payload), "blocks")
    end

    test "blocks=true is accepted rather than rejected as an unknown parameter", %{
      user: user,
      raw_key: key
    } do
      # OpenApiSpex rejects undeclared query parameters, so before #881 this
      # was a hard 422 and the SDK had to special-case the endpoint.
      insert_teammate_conv(user, insert_agent(user_id: user.id))

      conn = stream_async(key, [], "/api/team/stream?blocks=true") |> Task.await(5_000)
      assert conn.status == 200
    end
  end
end
