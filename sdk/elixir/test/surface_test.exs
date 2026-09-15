defmodule Fountain.SurfaceTest do
  use ExUnit.Case

  alias Fountain.{
    Agents,
    ConnectionProviders,
    Connections,
    Conversation,
    Environments,
    Secrets,
    Team,
    TeamSchedules,
    Vaults
  }

  test "resource, connection, sandbox, conversation action and schedule wrappers preserve endpoints and envelopes" do
    owner = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(owner, {:seen, request})
        route(request)
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url)

    assert {:ok, [%{"id" => "a1"}]} = Agents.list(client.agents, "alp")
    assert {:ok, %{"id" => "a1"}} = Agents.get(client.agents, "Alpha")
    assert {:ok, %{"id" => "a2"}} = Agents.create(client.agents, %{"name" => "Beta"})

    assert {:ok, %{"name" => "Renamed"}} =
             Agents.update(client.agents, "Alpha", %{"name" => "Renamed"})

    assert :ok = Agents.delete(client.agents, "Alpha")

    assert {:ok, [%{"id" => "e1"}]} = Environments.list(client.environments)

    assert {:ok, %{"key" => "TOKEN"}} =
             Secrets.set(client.environments.secrets, "Env", "TOKEN", "secret")

    assert {:ok, [%{"key" => "A"}, %{"key" => "B"}]} =
             Secrets.set_all(client.environments.secrets, "Env", %{"A" => "1", "B" => "2"})

    assert :ok = Secrets.delete(client.environments.secrets, "Env", "TOKEN")

    assert {:ok, [%{"id" => "v1"}]} = Vaults.list(client.vaults)
    assert {:ok, [%{"key" => "TOKEN"}]} = Secrets.list(client.vaults.secrets, "Vault")

    assert {:ok, [%{"id" => "c1"}]} = Connections.list(client.connections)
    assert {:ok, %{"id" => "c1"}} = Connections.get(client.connections, "c1")
    assert :ok = Connections.delete(client.connections, "c1")
    providers = client.connections.providers
    assert {:ok, [%{"id" => "google"}]} = ConnectionProviders.list(providers)
    assert {:ok, %{"id" => "google"}} = ConnectionProviders.get(providers, "google")
    assert {:ok, %{"id" => "p1"}} = ConnectionProviders.create(providers, %{"kind" => "mcp"})

    assert {:ok, %{"id" => "p1"}} =
             ConnectionProviders.update(providers, "p1", %{"name" => "new"})

    assert {:ok, %{"id" => "p1"}} = ConnectionProviders.discover(providers, "p1")
    assert :ok = ConnectionProviders.delete(providers, "p1")

    assert {:ok, %{"entries" => []}} = Fountain.sandbox_files(client, "s1", "src")

    assert {:ok, %{"content" => "hello"}} =
             Fountain.sandbox_file(client, "s1", "README", max_bytes: 10)

    assert {:ok, %{"diff" => "patch"}} =
             Fountain.sandbox_diff(client, "s1", staged: true, ref: "main", max_bytes: 20)

    conversation = Fountain.resume(client, "thread")

    assert {:ok, [%{"id" => 1}, %{"id" => 2}]} =
             Conversation.history(conversation, streams: [:acp], limit: 1)

    assert {:ok, 2} = Conversation.cursor(conversation)
    assert :ok = Conversation.answer(conversation, "req/1", "allow")
    assert :ok = Conversation.mark_read(conversation)

    # Omitted keeps a binding, an explicit nil clears it, and the two have to
    # stay distinguishable all the way to the wire.
    assert {:ok, %{"id" => "thread"}} = Conversation.reapply(conversation)

    assert {:ok, %{"id" => "thread"}} =
             Conversation.reapply(conversation, agent_id: "a1", vault_id: nil)

    assert :ok = Conversation.interrupt(conversation)
    assert :ok = Conversation.terminate(conversation)
    assert :ok = Conversation.delete(conversation)

    schedules = client.team.schedules
    assert {:ok, [%{"id" => "sch1"}]} = TeamSchedules.list(schedules)
    assert {:ok, %{"id" => "sch1"}} = TeamSchedules.get(schedules, "Alpha", "sch1")

    assert {:ok, %{"id" => "sch1"}} =
             TeamSchedules.create(schedules, "Alpha", %{"cron" => "* * * * *"})

    assert {:ok, %{"id" => "sch1"}} =
             TeamSchedules.update(schedules, "Alpha", "sch1", %{"enabled" => false})

    assert {:ok, %{"status" => "queued"}} = TeamSchedules.run(schedules, "Alpha", "sch1")
    assert :ok = TeamSchedules.delete(schedules, "Alpha", "sch1")

    assert_receive {:seen,
                    %{
                      path: "/api/sandboxes/s1/file",
                      query: %{"max_bytes" => "10", "path" => "README"}
                    }}

    assert_receive {:seen,
                    %{
                      path: "/api/sandboxes/s1/diff",
                      query: %{"max_bytes" => "20", "ref" => "main", "staged" => "true"}
                    }}

    assert_receive {:seen,
                    %{path: "/api/conversations/thread/requests/req%2F1", body: permission_body}}

    assert Jason.decode!(permission_body) == %{"option_id" => "allow"}

    assert_receive {:seen, %{path: "/api/conversations/thread/reapply", body: refresh_body}}
    assert Jason.decode!(refresh_body) == %{}

    assert_receive {:seen, %{path: "/api/conversations/thread/reapply", body: select_body}}
    assert Jason.decode!(select_body) == %{"agent_id" => "a1", "vault_id" => nil}
  end

  test "root run sends all options and a fresh channel follows turn one" do
    owner = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(owner, {:run_seen, request})

        case {request.method, request.path} do
          {"GET", "/api/agents"} ->
            json(200, %{"data" => [%{"id" => "a1", "name" => "Alpha"}]})

          {"GET", "/api/environments"} ->
            json(200, %{"data" => [%{"id" => "e1", "name" => "Env"}]})

          {"GET", "/api/vaults"} ->
            json(200, %{"data" => [%{"id" => "v1", "name" => "Vault"}]})

          {"POST", "/api/conversations"} ->
            json(201, %{"data" => %{"id" => "run1", "status" => "running"}})

          {"GET", "/api/conversations/run1/turns"} ->
            json(200, %{"data" => [%{"turn_number" => 4}]})

          {"GET", "/api/conversations/run1/stream"} ->
            {200, [{"content-type", "text/event-stream"}], turn(1)}

          {"GET", "/api/conversations/run1"} ->
            json(200, %{"data" => %{"id" => "run1", "status" => "done"}})
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url)

    run =
      Fountain.run(client, "prompt",
        agent: "Alpha",
        environment: "Env",
        vault: "Vault",
        title: "Title",
        images: [%{"url" => "x"}],
        channel_id: "channel",
        fresh: true,
        sprite_name: "box",
        sandbox: "s1",
        sandbox_mode: "persistent",
        sandbox_api_access: "owner"
      )

    assert {:ok, %{turn_number: 1, state: :done}} = Fountain.Run.await(run)
    assert_receive {:run_seen, %{method: "POST", path: "/api/conversations", body: body}}

    assert Jason.decode!(body) == %{
             "agent_id" => "a1",
             "environment_id" => "e1",
             "vault_id" => "v1",
             "prompt" => "prompt",
             "title" => "Title",
             "images" => [%{"url" => "x"}],
             "channel_id" => "channel",
             "fresh" => true,
             "sprite_name" => "box",
             "sandbox_id" => "s1",
             "sandbox_mode" => "persistent",
             "sandbox_api_access" => "owner"
           }
  end

  for access <- [nil, "none", "owner"] do
    test "run preserves sandbox API access #{inspect(access)} without inventing a default" do
      owner = self()

      server =
        Fountain.TestServer.start(fn request ->
          case {request.method, request.path} do
            {"GET", "/api/agents"} ->
              json(200, %{"data" => [%{"id" => "a1", "name" => "Alpha"}]})

            {"POST", "/api/conversations"} ->
              send(owner, {:access_body, Jason.decode!(request.body)})
              json(201, %{"data" => %{"id" => "run1", "status" => "running"}})

            {"GET", "/api/conversations/run1/stream"} ->
              {200, [{"content-type", "text/event-stream"}], turn(1)}

            {"GET", "/api/conversations/run1"} ->
              json(200, %{"data" => %{"id" => "run1", "status" => "done"}})
          end
        end)

      on_exit(fn -> Fountain.TestServer.stop(server) end)
      client = Fountain.new(api_key: "key", base_url: server.url)
      run = Fountain.run(client, "prompt", agent: "Alpha", sandbox_api_access: unquote(access))
      assert {:ok, _} = Fountain.Run.await(run)
      assert_receive {:access_body, body}
      assert body["sandbox_api_access"] == unquote(access)
      if is_nil(unquote(access)), do: refute(Map.has_key?(body, "sandbox_api_access"))
    end
  end

  test "conversation send and team message capture cursor and turn before posting" do
    owner = self()
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    server =
      Fountain.TestServer.start(fn request ->
        Agent.update(
          calls,
          &(&1 ++ [{request.method, request.path, request.query, request.headers}])
        )

        send(owner, {:followup_seen, request})

        case {request.method, request.path} do
          {"GET", "/api/agents"} ->
            json(200, %{"data" => [%{"id" => "a1", "name" => "Alpha"}]})

          {"GET", "/api/team/a1"} ->
            json(200, %{
              "data" => %{"agent_id" => "a1", "conversation" => %{"id" => "team-thread"}}
            })

          {"POST", "/api/team/a1/messages"} ->
            json(200, %{"conversation_id" => "team-thread"})

          {"GET", "/api/conversations/team-thread/turns"} ->
            json(200, %{"data" => [%{"turn_number" => 2}]})

          {"GET", "/api/conversations/team-thread"} ->
            json(200, %{"data" => %{"id" => "team-thread", "status" => "done"}})

          {"GET", "/api/conversations/team-thread/stream"} ->
            stream_for(request, 10, 3)

          {"GET", "/api/conversations/direct/turns"} ->
            json(200, %{"data" => [%{"turn_number" => 1}]})

          {"POST", "/api/conversations/direct/prompts"} ->
            {204, [], ""}

          {"GET", "/api/conversations/direct"} ->
            json(200, %{"data" => %{"id" => "direct", "status" => "done"}})

          {"GET", "/api/conversations/direct/stream"} ->
            stream_for(request, 20, 2)
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url)

    team_run = Team.message(client.team, "Alpha", "team prompt")

    assert {:ok, %{conversation_id: "team-thread", turn_number: 3, state: :done}} =
             Fountain.Run.await(team_run)

    direct = Conversation.new(client.api, "direct", 20)
    direct_run = Conversation.send(direct, "next", images: [%{"url" => "image"}])

    assert {:ok, %{conversation_id: "direct", turn_number: 2, state: :done}} =
             Fountain.Run.await(direct_run)

    seen = Agent.get(calls, & &1)

    cursor_index =
      Enum.find_index(seen, fn {method, path, query, _} ->
        method == "GET" and path == "/api/conversations/team-thread/stream" and
          query["wait"] == "false"
      end)

    turns_index =
      Enum.find_index(seen, fn {method, path, _, _} ->
        method == "GET" and path == "/api/conversations/team-thread/turns"
      end)

    post_index =
      Enum.find_index(seen, fn {method, path, _, _} ->
        method == "POST" and path == "/api/team/a1/messages"
      end)

    assert cursor_index < turns_index and turns_index < post_index

    assert Enum.any?(seen, fn {method, path, _, headers} ->
             method == "GET" and path == "/api/conversations/team-thread/stream" and
               headers["last-event-id"] == "10"
           end)

    assert_receive {:followup_seen,
                    %{method: "POST", path: "/api/conversations/direct/prompts", body: body}}

    assert Jason.decode!(body) == %{"prompt" => "next", "images" => [%{"url" => "image"}]}
  end

  defp route(request) do
    case {request.method, request.path} do
      {"GET", "/api/agents"} ->
        json(200, %{"data" => [%{"id" => "a1", "name" => "Alpha"}]})

      {"GET", "/api/agents/a1"} ->
        json(200, %{"data" => %{"id" => "a1"}})

      {"POST", "/api/agents"} ->
        json(201, %{"data" => %{"id" => "a2"}})

      {"PATCH", "/api/agents/a1"} ->
        json(200, %{"data" => %{"name" => "Renamed"}})

      {"DELETE", "/api/agents/a1"} ->
        {204, [], ""}

      {"GET", "/api/environments"} ->
        json(200, %{"data" => [%{"id" => "e1", "name" => "Env"}]})

      {"POST", "/api/environments/e1/secrets"} ->
        json(201, %{"data" => %{"key" => Jason.decode!(request.body)["key"]}})

      {"DELETE", "/api/environments/e1/secrets/TOKEN"} ->
        {204, [], ""}

      {"GET", "/api/vaults"} ->
        json(200, %{"data" => [%{"id" => "v1", "name" => "Vault"}]})

      {"GET", "/api/vaults/v1/secrets"} ->
        json(200, %{"data" => [%{"key" => "TOKEN"}]})

      {"GET", "/api/connections"} ->
        json(200, %{"data" => [%{"id" => "c1"}]})

      {"GET", "/api/connections/c1"} ->
        json(200, %{"id" => "c1"})

      {"DELETE", "/api/connections/c1"} ->
        {204, [], ""}

      {"GET", "/api/connection-providers"} ->
        json(200, %{"data" => [%{"id" => "google"}]})

      {"GET", "/api/connection-providers/google"} ->
        json(200, %{"id" => "google"})

      {"POST", "/api/connection-providers"} ->
        json(201, %{"id" => "p1"})

      {"PATCH", "/api/connection-providers/p1"} ->
        json(200, %{"id" => "p1"})

      {"POST", "/api/connection-providers/p1/discover"} ->
        json(200, %{"id" => "p1"})

      {"DELETE", "/api/connection-providers/p1"} ->
        {204, [], ""}

      {"GET", "/api/sandboxes/s1/files"} ->
        json(200, %{"data" => %{"entries" => []}})

      {"GET", "/api/sandboxes/s1/file"} ->
        json(200, %{"data" => %{"content" => "hello"}})

      {"GET", "/api/sandboxes/s1/diff"} ->
        json(200, %{"data" => %{"diff" => "patch"}})

      {"GET", "/api/conversations/thread/events"} ->
        history_page(request.query["after"])

      {"POST", "/api/conversations/thread/requests/req%2F1"} ->
        {204, [], ""}

      {"POST", "/api/conversations/thread/read"} ->
        {204, [], ""}

      {"POST", "/api/conversations/thread/reapply"} ->
        json(200, %{"data" => %{"id" => "thread"}})

      {"POST", "/api/conversations/thread/interrupt"} ->
        {204, [], ""}

      {"POST", "/api/conversations/thread/terminate"} ->
        {204, [], ""}

      {"DELETE", "/api/conversations/thread"} ->
        {204, [], ""}

      {"GET", "/api/team/schedules"} ->
        json(200, %{"data" => [%{"id" => "sch1"}]})

      {"GET", "/api/team/a1/schedules/sch1"} ->
        json(200, %{"data" => %{"id" => "sch1"}})

      {"POST", "/api/team/a1/schedules"} ->
        json(201, %{"data" => %{"id" => "sch1"}})

      {"PATCH", "/api/team/a1/schedules/sch1"} ->
        json(200, %{"data" => %{"id" => "sch1"}})

      {"POST", "/api/team/a1/schedules/sch1/run"} ->
        json(200, %{"status" => "queued"})

      {"DELETE", "/api/team/a1/schedules/sch1"} ->
        {204, [], ""}
    end
  end

  defp history_page("0"),
    do:
      json(200, %{"data" => [%{"id" => 1}], "meta" => %{"has_more" => true, "next_cursor" => 1}})

  defp history_page("1"),
    do: json(200, %{"data" => [%{"id" => 2}], "meta" => %{"has_more" => false}})

  defp stream_for(%{query: %{"wait" => "false"}}, cursor, _turn),
    do:
      {200, [{"content-type", "text/event-stream"}],
       sse(cursor, "stage", %{
         "stage" => "turn",
         "state" => "done",
         "data" => %{"turn_number" => 1}
       })}

  defp stream_for(_request, cursor, turn_number),
    do:
      {200, [{"content-type", "text/event-stream"}],
       [
         sse(cursor + 1, "stage", %{
           "stage" => "turn",
           "state" => "started",
           "data" => %{"turn_number" => turn_number}
         }),
         sse(cursor + 2, "stage", %{
           "stage" => "turn",
           "state" => "done",
           "data" => %{"turn_number" => turn_number}
         })
       ]}

  test "a missing teammate is a resolution error, not a request for the whole team" do
    owner = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(owner, {:unexpected, request})
        json(200, %{"data" => []})
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url, app_url: "")
    schedules = client.team.schedules

    # `GET /api/team/` routes to the index action, so a nil that survives
    # resolution reads back every teammate on the account as if it were one.
    for agent <- [nil, "", "   "] do
      assert {:error, %Fountain.Error{kind: :resolution}} = Team.get(client.team, agent)
      assert {:error, %Fountain.Error{kind: :resolution}} = Team.remove(client.team, agent)
      assert {:error, %Fountain.Error{kind: :resolution}} = Team.rename(client.team, agent, "x")
      assert {:error, %Fountain.Error{kind: :resolution}} = Team.history(client.team, agent)

      assert {:error, %Fountain.Error{kind: :resolution}} =
               Team.fresh_conversation(client.team, agent)

      assert {:error, %Fountain.Error{kind: :resolution}} =
               TeamSchedules.get(schedules, agent, "sch1")

      assert {:error, %Fountain.Error{kind: :resolution}} =
               TeamSchedules.create(schedules, agent, %{"cron" => "* * * * *"})
    end

    refute_receive {:unexpected, _}, 100
  end

  test "conversation handles do not leak an ETS table each" do
    client = Fountain.new(api_key: "key", base_url: "http://127.0.0.1:1", app_url: "")
    before = length(:ets.all())

    # The table a handle used to allocate was owned by the calling process, so a
    # GenServer that resumes a conversation per inbound message accumulated one
    # per call until it hit the system limit.
    handles = Enum.map(1..200, fn n -> Fountain.resume(client, "c#{n}") end)

    assert length(handles) == 200
    assert length(:ets.all()) - before < 50

    refute Enum.any?(:ets.all(), fn table ->
             :ets.info(table, :name) == :fountain_conversation_cursor
           end)

    assert {:ok, 9} = Conversation.cursor(Conversation.new(client.api, "seeded", 9))
  end

  test "a conversation cursor is shared with processes the handle is passed to" do
    server =
      Fountain.TestServer.start(fn _request ->
        json(200, %{"data" => [%{"id" => 11}, %{"id" => 17}]})
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url, app_url: "")
    conversation = Fountain.resume(client, "c1")
    parent = self()

    # The cursor outlived the creating process only because the ETS table was
    # public; an atomics ref has to stay just as shareable.
    spawn(fn ->
      {:ok, _} = Conversation.history(conversation)
      send(parent, :read)
    end)

    assert_receive :read
    assert {:ok, 17} = Conversation.cursor(conversation)
  end

  defp json(status, value),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(value)}

  defp turn(number),
    do: [
      sse(1, "stage", %{
        "stage" => "turn",
        "state" => "started",
        "data" => %{"turn_number" => number}
      }),
      sse(2, "stage", %{
        "stage" => "turn",
        "state" => "done",
        "data" => %{"turn_number" => number}
      })
    ]

  defp sse(id, event, data), do: "id: #{id}\nevent: #{event}\ndata: #{Jason.encode!(data)}\n\n"
end
