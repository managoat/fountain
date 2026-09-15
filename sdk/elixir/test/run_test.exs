defmodule Fountain.TimeoutTransport do
  def request("GET", url, _headers, _body, _timeout) do
    cond do
      String.ends_with?(url, "/api/agents") ->
        {:ok, 200, [], Jason.encode!(%{"data" => [%{"id" => "agent-1", "name" => "writer"}]})}

      String.ends_with?(url, "/api/conversations/c2") ->
        {:ok, 200, [], Jason.encode!(%{"data" => %{"id" => "c2", "status" => "running"}})}
    end
  end

  def request("POST", _url, _headers, _body, _timeout),
    do: {:ok, 201, [], Jason.encode!(%{"data" => %{"id" => "c2", "status" => "running"}})}

  def stream("GET", _url, _headers, _timeout, on_chunk) do
    on_chunk.(
      "id: 1\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1}}\n\nid: 2\nevent: output\ndata: {\"stream\":\"acp\",\"blocks\":[{\"kind\":\"text\",\"body\":\"partial\"}]}\n\n"
    )

    Process.sleep(500)
    {:error, :timeout}
  end
end

defmodule Fountain.GatedRunTransport do
  def request("GET", url, _headers, _body, _timeout) do
    cond do
      String.ends_with?(url, "/api/agents") ->
        {:ok, 200, [], Jason.encode!(%{"data" => [%{"id" => "agent-1", "name" => "writer"}]})}

      String.ends_with?(url, "/api/conversations/gated") ->
        {:ok, 200, [], Jason.encode!(%{"data" => %{"id" => "gated", "status" => "done"}})}
    end
  end

  def request("POST", _url, _headers, _body, _timeout),
    do: {:ok, 201, [], Jason.encode!(%{"data" => %{"id" => "gated", "status" => "running"}})}

  def stream("GET", _url, _headers, _timeout, on_chunk) do
    owner = :persistent_term.get({__MODULE__, :owner})
    send(owner, {:gated_stream_ready, self()})

    receive do
      :emit -> :ok
    end

    on_chunk.(
      IO.iodata_to_binary([
        "id: 1\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1}}\n\n",
        "id: 2\nevent: output\ndata: {\"stream\":\"acp\",\"blocks\":[{\"kind\":\"text\",\"body\":\"one\"}]}\n\n",
        "id: 3\nevent: output\ndata: {\"stream\":\"acp\",\"blocks\":[{\"kind\":\"text\",\"body\":\"two\"}]}\n\n"
      ])
    )

    send(owner, {:gated_events_emitted, self()})

    receive do
      :finish -> :ok
    end

    on_chunk.(
      "id: 4\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\",\"data\":{\"turn_number\":1}}\n\n"
    )

    {:ok, 200, [], nil}
  end
end

defmodule Fountain.RunTest do
  use ExUnit.Case
  alias Fountain.{Error, Run}

  test "run_request forwards wire fields and leaves local options outside the body" do
    parent = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(parent, {:wire_request, request})

        case {request.method, request.path} do
          {"POST", "/api/conversations"} ->
            json(201, %{"data" => %{"id" => "c1", "status" => "running"}})

          {"GET", "/api/conversations/c1/stream"} ->
            {200, [{"content-type", "text/event-stream"}], run_events()}

          {"GET", "/api/conversations/c1"} ->
            json(200, %{"data" => %{"id" => "c1", "status" => "done"}})
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url)

    body = %{
      "agent_id" => "agent-1",
      "prompt" => "hello",
      "title" => "",
      "vault_id" => nil,
      "fresh" => false,
      "queue" => false,
      "images" => [],
      "labels" => %{"attempt" => "0"},
      "permission_policy" => %{"ask_timeout" => 0},
      "sandbox_api_access" => "none"
    }

    run = Fountain.run_request(client, body, timeout: 1_000, collect_events: true)
    assert {:ok, result} = Run.await(run)
    assert result.text == "Hello\n\nworld"
    assert length(result.events) == 4
    assert_receive {:wire_request, %{method: "POST", path: "/api/conversations", body: encoded}}
    assert Jason.decode!(encoded) == body
    refute_receive {:wire_request, %{path: "/api/agents"}}
  end

  test "legacy empty values retain wire semantics and reach server validation" do
    owner = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(owner, {:legacy_request, request})
        json(422, %{"error" => "unprocessable_entity"})
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url)

    run =
      Fountain.run(client, "",
        agent: "11111111-1111-1111-1111-111111111111",
        title: "",
        images: [],
        fresh: false,
        timeout: 1_000,
        collect_events: true
      )

    assert {:error, %Error{status: 422}} = Run.await(run)
    assert_receive {:legacy_request, %{method: "POST", path: "/api/conversations", body: body}}

    assert Jason.decode!(body) == %{
             "agent_id" => "11111111-1111-1111-1111-111111111111",
             "title" => ""
           }

    refute_receive {:legacy_request, _}
  end

  defp launch_channel(client, :run_request, request, options),
    do: Fountain.run_request(client, request, options)

  defp launch_channel(client, :run, request, options) do
    Fountain.run(
      client,
      request["prompt"],
      options ++
        [
          agent: "11111111-1111-1111-1111-111111111111",
          channel_id: request["channel_id"],
          fresh: request["fresh"],
          images: request["images"]
        ]
    )
  end

  for entry <- [:run_request, :run], fresh <- [false, true] do
    @entry entry
    @fresh fresh
    test "#{entry} follows the initial turn of a new channel with fresh=#{fresh}" do
      parent = self()

      server =
        Fountain.TestServer.start(fn request ->
          send(parent, {:channel_request, request})

          case {request.method, request.path} do
            {"POST", "/api/conversations"} ->
              json(201, %{
                "data" => %{"id" => "c1", "status" => "running"},
                "meta" => %{"resumed" => false}
              })

            {"GET", "/api/conversations/c1/turns"} ->
              json(200, %{"data" => [%{"turn_number" => 1, "status" => "completed"}]})

            {"GET", "/api/conversations/c1/stream"} ->
              {200, [{"content-type", "text/event-stream"}], run_events()}

            {"GET", "/api/conversations/c1"} ->
              json(200, %{"data" => %{"id" => "c1", "status" => "ready"}})
          end
        end)

      on_exit(fn -> Fountain.TestServer.stop(server) end)
      client = Fountain.new(api_key: "key", base_url: server.url)

      run =
        launch_channel(
          client,
          @entry,
          %{
            "agent_id" => "agent-1",
            "prompt" => "hello",
            "channel_id" => "raw",
            "fresh" => @fresh
          },
          timeout: 1_000
        )

      assert {:ok, result} = Run.await(run)
      assert result.turn_number == 1
      assert result.text == "Hello\n\nworld"
      refute_receive {:channel_request, %{path: "/api/conversations/c1/prompts"}}
    end
  end

  for entry <- [:run_request, :run] do
    @entry entry
    test "#{entry} submits prompt and images to a resumed channel before following its next turn" do
      parent = self()
      {:ok, submitted} = Agent.start_link(fn -> false end)

      server =
        Fountain.TestServer.start(fn request ->
          send(parent, {:channel_request, request})

          case {request.method, request.path} do
            {"POST", "/api/conversations"} ->
              json(200, %{
                "data" => %{"id" => "c1", "status" => "ready"},
                "meta" => %{"resumed" => true}
              })

            {"GET", "/api/conversations/c1/turns"} ->
              # Only the old turn exists until the prompt is actually submitted.
              assert Agent.get(submitted, & &1) == false
              json(200, %{"data" => [%{"turn_number" => 1, "status" => "completed"}]})

            {"POST", "/api/conversations/c1/prompts"} ->
              Agent.update(submitted, fn _ -> true end)
              json(200, %{"status" => "queued"})

            {"GET", "/api/conversations/c1/stream"} ->
              events = if Agent.get(submitted, & &1), do: run_events(2, 4), else: run_events()
              {200, [{"content-type", "text/event-stream"}], events}

            {"GET", "/api/conversations/c1"} ->
              json(200, %{"data" => %{"id" => "c1", "status" => "ready"}})
          end
        end)

      on_exit(fn -> Fountain.TestServer.stop(server) end)
      client = Fountain.new(api_key: "key", base_url: server.url)
      images = [%{"data" => "aGVsbG8=", "media_type" => "image/png"}]

      run =
        launch_channel(
          client,
          @entry,
          %{
            "agent_id" => "agent-1",
            "prompt" => "next",
            "channel_id" => "raw",
            "images" => images
          },
          timeout: 1_000,
          collect_events: true
        )

      assert {:ok, result} = Run.await(run)
      assert result.conversation_id == "c1"
      assert result.turn_number == 2
      assert result.text == "Hello\n\nworld"

      assert_receive {:channel_request,
                      %{method: "POST", path: "/api/conversations/c1/prompts", body: body}}

      assert Jason.decode!(body) == %{"prompt" => "next", "images" => images}
      refute_receive {:channel_request, %{path: "/api/conversations/c1/prompts"}}
    end
  end

  test "run_request rejects ambiguous keys and unsupported lifecycles before HTTP" do
    client = Fountain.new(api_key: "key", base_url: "http://127.0.0.1:1")

    assert_raise ArgumentError, ~r/string keys/, fn ->
      Fountain.run_request(client, %{agent_id: "a", prompt: "hi"})
    end

    for prompt <- [nil, "", "  "] do
      assert_raise ArgumentError, ~r/non-empty prompt/, fn ->
        Fountain.run_request(client, %{"agent_id" => "a", "prompt" => prompt})
      end
    end

    assert_raise ArgumentError, ~r/queued/, fn ->
      Fountain.run_request(client, %{"agent_id" => "a", "prompt" => "hi", "queue" => true})
    end
  end

  test "run starts immediately and broadcasts one underlying turn to late consumers" do
    parent = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(parent, {:request, request})

        case {request.method, request.path} do
          {"GET", "/api/agents"} ->
            json(200, %{"data" => [%{"id" => "agent-1", "name" => "writer"}]})

          {"POST", "/api/conversations"} ->
            json(201, %{"data" => %{"id" => "c1", "status" => "running"}})

          {"GET", "/api/conversations/c1/stream"} ->
            {200, [{"content-type", "text/event-stream"}], run_events()}

          {"GET", "/api/conversations/c1"} ->
            json(200, %{"data" => %{"id" => "c1", "status" => "done"}})
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url, app_url: "")
    run = Fountain.run(client, "hello", agent: "writer", collect_events: true)

    assert_receive {:request, %{method: "POST", path: "/api/conversations"}}, 1_000
    assert {:ok, result} = Run.await(run)
    assert result.conversation_id == "c1"
    assert result.text == "Hello\n\nworld"
    assert result.tools_used == ["search"]
    assert result.state == :done
    assert length(result.events) == 4

    events_one = Enum.to_list(Run.stream(run))
    events_two = Enum.to_list(Run.stream(run))
    assert events_one == events_two
    assert Enum.map(Enum.to_list(Run.text_stream(run)), & &1) == ["Hello", "\n\nworld"]
  end

  test "run timeout preserves conversation id and partial text" do
    client =
      Fountain.new(
        api_key: "key",
        base_url: "https://example.test",
        app_url: "",
        transport: Fountain.TimeoutTransport
      )

    run = Fountain.run(client, "hello", agent: "writer", timeout: 150)

    assert {:error, %Error{kind: :timeout, conversation_id: "c2", partial_text: "partial"}} =
             Run.await(run)
  end

  test "run server and worker are cleaned up when their owner exits" do
    parent = self()

    # spawn_monitor, not spawn + Process.monitor: the fun below finishes in
    # microseconds, so a monitor placed after the spawn regularly attaches to a
    # process that has already exited and fires :noproc instead of :normal.
    {owner, monitor} =
      spawn_monitor(fn ->
        run = Run.new(%{}, fn -> Process.sleep(:infinity) end)
        send(parent, {:run_server, run.server})
      end)

    assert_receive {:run_server, server}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    server_monitor = Process.monitor(server)
    assert_receive {:DOWN, ^server_monitor, :process, ^server, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  test "a stream held in another process raises instead of hanging when the run ends" do
    parent = self()

    owner =
      spawn(fn ->
        run = Run.new(%{}, fn -> Process.sleep(:infinity) end)
        send(parent, {:run, run})
        Process.sleep(:infinity)
      end)

    assert_receive {:run, run}

    consumer =
      Task.async(fn ->
        try do
          {:finished, Enum.to_list(Run.stream(run))}
        rescue
          error -> {:raised, error}
        end
      end)

    # The moduledoc invites passing the handle to consumers. When the owner goes
    # away the server stops `:normal`, and without a monitor the consumer's
    # `receive` waits on a mailbox nothing will ever post to again.
    wait_for_subscribers(run.server, 1)
    Process.exit(owner, :kill)

    assert {:raised, %Error{kind: :connection}} = Task.await(consumer, 2_000)
  end

  test "halting one live stream cannot duplicate queued events in a later subscription" do
    :persistent_term.put({Fountain.GatedRunTransport, :owner}, self())
    on_exit(fn -> :persistent_term.erase({Fountain.GatedRunTransport, :owner}) end)

    client =
      Fountain.new(
        api_key: "key",
        base_url: "https://example.test",
        transport: Fountain.GatedRunTransport
      )

    run = Fountain.run(client, "hello", agent: "writer")
    assert_receive {:gated_stream_ready, producer}

    consumer =
      Task.async(fn ->
        first = Enum.take(Run.text_stream(run), 1)
        send(self_owner(), {:first_stream_halted, self()})
        second = Enum.to_list(Run.text_stream(run))
        messages = self() |> Process.info(:messages) |> elem(1)
        {first, second, messages}
      end)

    wait_for_subscribers(run.server, 1)
    send(producer, :emit)
    consumer_pid = consumer.pid
    assert_receive {:first_stream_halted, ^consumer_pid}
    assert_receive {:gated_events_emitted, ^producer}
    wait_for_subscribers(run.server, 1)
    send(producer, :finish)

    assert {["one"], ["one", "two"], messages} = Task.await(consumer)
    refute Enum.any?(messages, &match?({:fountain_run, _, _, _}, &1))
    assert {:ok, %{text: "onetwo"}} = Run.await(run)
  end

  defp self_owner, do: :persistent_term.get({Fountain.GatedRunTransport, :owner})

  defp wait_for_subscribers(server, count, attempts \\ 100)
  defp wait_for_subscribers(_server, _count, 0), do: flunk("subscriber count did not settle")

  defp wait_for_subscribers(server, count, attempts) do
    if map_size(:sys.get_state(server).subscribers) == count do
      :ok
    else
      Process.sleep(5)
      wait_for_subscribers(server, count, attempts - 1)
    end
  end

  defp json(status, value),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(value)}

  defp run_events(turn_number \\ 1, offset \\ 0) do
    turn_id = "t#{turn_number}"

    [
      sse(offset + 1, "stage", %{
        "stage" => "turn",
        "state" => "started",
        "data" => %{"turn_number" => turn_number, "turn_id" => turn_id}
      }),
      sse(offset + 2, "output", %{
        "turn_id" => turn_id,
        "stream" => "acp",
        "blocks" => [
          %{"kind" => "text", "body" => "Hello"},
          %{"kind" => "tool_use", "name" => "search"}
        ]
      }),
      sse(offset + 3, "output", %{
        "turn_id" => turn_id,
        "stream" => "acp",
        "blocks" => [%{"kind" => "text", "body" => "world"}]
      }),
      sse(offset + 4, "stage", %{
        "stage" => "turn",
        "state" => "done",
        "data" => %{"turn_number" => turn_number, "turn_id" => turn_id, "exit_code" => 0}
      })
    ]
  end

  defp sse(id, event, data), do: "id: #{id}\nevent: #{event}\ndata: #{Jason.encode!(data)}\n\n"
end
