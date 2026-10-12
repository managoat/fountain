defmodule Fountain.HttpSseTest do
  use ExUnit.Case
  alias Fountain.{Error, HTTP, SSE}

  setup do
    on_exit(fn -> :ok end)
    :ok
  end

  test "a 402 is an ordinary API error now that credits are gone" do
    error =
      Error.for_status(402, %{"error" => "insufficient_credits"}, "POST", "/api/conversations")

    assert %Error{kind: :api, status: 402, code: "insufficient_credits"} = error
    refute Error.retryable?(error)
    refute function_exported?(Error, :upgrade_url, 1)
  end

  test "HTTP sends auth, JSON and parent attribution and maps API errors" do
    parent = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(parent, {:request, request})

        case request.path do
          "/ok" ->
            {200, [{"content-type", "application/json"}],
             Jason.encode!(%{"data" => %{"ok" => true}})}

          "/bad" ->
            {422, [{"content-type", "application/json"}, {"retry-after", "2.5"}],
             Jason.encode!(%{"error" => "invalid", "errors" => %{"name" => ["required"]}})}
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)

    config = %Fountain.Config{
      base_url: server.url,
      api_key: "secret",
      app_url: "",
      parent_conversation_id: "parent-1"
    }

    http = HTTP.new(config)

    assert {:ok, %{"ok" => true}} = HTTP.data(http, "POST", "/ok", body: %{"hello" => "world"})
    assert_receive {:request, request}
    assert request.headers["authorization"] == "Bearer secret"
    assert request.headers["x-fountain-parent-conversation-id"] == "parent-1"
    assert Jason.decode!(request.body) == %{"hello" => "world"}

    assert {:error, %Error{kind: :validation, status: 422} = error} =
             HTTP.request(http, "GET", "/bad")

    assert Error.field_errors(error) == %{"name" => ["required"]}
    assert error.retry_after == 2.5
  end

  test "SSE parser handles split CRLF, comments, multiline data, and final tail" do
    chunks = [
      ": ping\r\nid: 1\r\nevent: output\r\ndata: {\"a\":\r\n",
      "data: 1}\r\n\r\nid: 2\ndata: tail"
    ]

    assert [first, second] = SSE.parse_sse(chunks)
    assert first == %{"id" => "1", "event" => "output", "data" => "{\"a\":\n1}"}
    assert second == %{"id" => "2", "event" => "message", "data" => "tail"}
  end

  test "SSE emits a 4xx error and does not reconnect" do
    server =
      Fountain.TestServer.start(fn _request ->
        {401, [{"content-type", "application/json"}, {"retry-after", "3"}],
         Jason.encode!(%{"error" => "unauthorized", "message" => "bad stream key"})}
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "bad", app_url: ""})

    error =
      assert_raise Error, fn ->
        Enum.to_list(SSE.stream_path(http, "/stream", max_retries: 3, retry_delay: 0))
      end

    assert error.kind == :auth
    assert error.code == "unauthorized"
    assert error.body == %{"error" => "unauthorized", "message" => "bad stream key"}
    assert error.retry_after == 3.0
  end

  test "SSE retries a 5xx response" do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    server =
      Fountain.TestServer.start(fn _request ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            {503, [{"content-type", "application/json"}],
             Jason.encode!(%{"error" => "provisioning"})}

          _ ->
            {200, [{"content-type", "text/event-stream"}],
             "id: 9\nevent: stage\ndata: {\"state\":\"done\"}\n\n"}
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})

    assert [%{"id" => 9, "kind" => "stage"}] =
             SSE.stream_path(http, "/stream", wait: false, max_retries: 1, retry_delay: 0)
             |> Enum.to_list()

    assert Agent.get(calls, & &1) == 2
  end

  test "raw absolute URLs cannot carry credentials to another origin" do
    http =
      HTTP.new(%Fountain.Config{
        base_url: "https://fountain.example",
        api_key: "secret",
        app_url: ""
      })

    assert {:error, %Error{} = error} =
             HTTP.request(http, "GET", "https://attacker.example/collect")

    # The guard is a caller mistake, not a transport failure. Reporting it as
    # :connection would put it in the same bucket as "the network is down",
    # which is the bucket callers are told to retry.
    assert error.kind == :validation
    refute Error.retryable?(error)
  end

  test "a connection that delivered events starts the retry budget over" do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    server =
      Fountain.TestServer.start(fn _request ->
        call = Agent.get_and_update(calls, &{&1, &1 + 1})
        body = "id: #{call + 1}\nevent: stage\ndata: {\"stage\":\"turn\"}\n\n"

        # Three connections stream an event and then die; the fourth ends
        # cleanly. With `max_retries: 1` a client that carried the attempt
        # count across successful connections would give up on the second.
        if call < 3,
          do: {:abort, 200, [{"content-type", "text/event-stream"}], [{0, body}]},
          else: {200, [{"content-type", "text/event-stream"}], body}
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})

    events =
      SSE.stream_path(http, "/stream", wait: false, max_retries: 1, retry_delay: 0)
      |> Enum.to_list()

    assert Enum.map(events, & &1["id"]) == [1, 2, 3, 4]
    assert Agent.get(calls, & &1) == 4
  end

  test "a connection that delivered nothing still exhausts the retry budget" do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    server =
      Fountain.TestServer.start(fn _request ->
        Agent.update(calls, &(&1 + 1))
        {:abort, 200, [{"content-type", "text/event-stream"}], []}
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})

    assert_raise Error, fn ->
      SSE.stream_path(http, "/stream", wait: false, max_retries: 2, retry_delay: 0)
      |> Enum.to_list()
    end

    assert Agent.get(calls, & &1) == 3
  end

  test "ordinary and SSE requests never follow redirects with bearer credentials" do
    owner = self()

    destination =
      Fountain.TestServer.start(fn request ->
        send(owner, {:credential_leak, request})
        {200, [{"content-type", "application/json"}], "{}"}
      end)

    redirect =
      Fountain.TestServer.start(fn _request ->
        {302, [{"location", destination.url <> "/collect"}], "redirecting"}
      end)

    on_exit(fn ->
      Fountain.TestServer.stop(redirect)
      Fountain.TestServer.stop(destination)
    end)

    http = HTTP.new(%Fountain.Config{base_url: redirect.url, api_key: "top-secret", app_url: ""})
    assert {:error, %Error{status: 302}} = HTTP.request(http, "GET", "/ordinary")

    assert_raise Error, fn ->
      SSE.stream_path(http, "/stream", max_retries: 0) |> Enum.to_list()
    end

    refute_receive {:credential_leak, _}, 100
  end

  test "HTTP transport never transparently retries a failed POST" do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    server =
      Fountain.TestServer.start(fn _request ->
        call = Agent.get_and_update(calls, fn count -> {count + 1, count + 1} end)

        if call == 1 do
          {503, [{"content-type", "application/json"}, {"retry-after", "0"}],
           Jason.encode!(%{"error" => "provisioning"})}
        else
          {200, [{"content-type", "application/json"}], Jason.encode!(%{"data" => "retried"})}
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})

    assert {:error, %Error{status: 503, kind: :not_ready}} =
             HTTP.request(http, "POST", "/api/conversations", body: %{"agent_id" => "a1"})

    Process.sleep(25)
    assert Agent.get(calls, & &1) == 1
  end

  test "user agent version matches the package version" do
    assert HTTP.user_agent() == "fountain-sdk-elixir/#{Mix.Project.config()[:version]}"
  end

  test "SSE decodes raw maps and resumes with Last-Event-ID" do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)
    parent = self()

    server =
      Fountain.TestServer.start(fn request ->
        call = Agent.get_and_update(calls, &{&1, &1 + 1})
        send(parent, {:stream_request, call, request})

        body =
          if call == 0,
            do: "id: 4\nevent: output\ndata: {\"blocks\":[],\"stream\":\"acp\"}\n\n",
            else: "id: 5\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\"}\n\n"

        {200, [{"content-type", "text/event-stream"}], body}
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})

    assert [%{"id" => 4, "kind" => "output"}, %{"id" => 5, "kind" => "stage"}] =
             SSE.stream_path(http, "/stream", max_retries: 1, retry_delay: 0) |> Enum.take(2)

    assert_receive {:stream_request, 0, first}
    refute Map.has_key?(first.headers, "last-event-id")
    assert_receive {:stream_request, 1, second}
    assert second.headers["last-event-id"] == "4"
  end

  test "halting a fast raw SSE stream drains its subscription mailbox" do
    body =
      Enum.map(1..20, fn id ->
        "id: #{id}\nevent: output\ndata: {\"blocks\":[],\"value\":#{id}}\n\n"
      end)

    server =
      Fountain.TestServer.start(fn _request ->
        {200, [{"content-type", "text/event-stream"}], body}
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})
    assert [%{"id" => 1}] = SSE.stream_path(http, "/stream") |> Enum.take(1)

    messages = self() |> Process.info(:messages) |> elem(1)
    refute Enum.any?(messages, &match?({:fountain_sse, _, _}, &1))
  end

  test "HTTP streaming applies transport backpressure while a chunk consumer is blocked" do
    chunks = List.duplicate({0, :binary.copy("x", 4_096)}, 512)

    server =
      Fountain.TestServer.start(fn _request ->
        {:stream, 200, [{"content-type", "text/event-stream"}], chunks}
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    http = HTTP.new(%Fountain.Config{base_url: server.url, api_key: "key", app_url: ""})
    parent = self()

    worker =
      spawn(fn ->
        result =
          HTTP.stream(http, "GET", "/stream", [timeout: :infinity], fn _chunk ->
            unless Process.get(:consumer_released) do
              send(parent, {:consumer_blocked, self()})

              receive do
                :release_consumer -> Process.put(:consumer_released, true)
              end
            end
          end)

        send(parent, {:stream_result, result})
      end)

    assert_receive {:consumer_blocked, ^worker}, 1_000
    Process.sleep(50)
    assert {:message_queue_len, 0} = Process.info(worker, :message_queue_len)

    send(worker, :release_consumer)
    assert_receive {:stream_result, :ok}, 2_000
  end
end
