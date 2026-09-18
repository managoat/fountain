defmodule Fountain.ConformanceTest do
  use ExUnit.Case

  alias Fountain.{Agents, Conversation, Environments, Error, Run, Vaults}

  @sdk "elixir"
  @conformance Path.expand("../../conformance", __DIR__)
  @matrix @conformance |> Path.join("matrix.json") |> File.read!() |> Jason.decode!()
  @scenarios @conformance
             |> Path.join("scenarios/*.json")
             |> Path.wildcard()
             |> Enum.sort()
             |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)

  defmodule ScriptedServer do
    @moduledoc false

    def start(exchanges) do
      {:ok, state} =
        Agent.start_link(fn ->
          %{exchanges: exchanges, consumed: MapSet.new(), requests: [], unmatched: []}
        end)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, {_address, port}} = :inet.sockname(listener)
      acceptor = spawn(fn -> accept(listener, state) end)

      %{
        listener: listener,
        acceptor: acceptor,
        state: state,
        url: "http://127.0.0.1:#{port}"
      }
    end

    def observations(server) do
      Agent.get(server.state, fn state ->
        %{
          requests: Enum.reverse(state.requests),
          unmatched: Enum.reverse(state.unmatched)
        }
      end)
    end

    def stop(server) do
      :gen_tcp.close(server.listener)

      if Process.alive?(server.acceptor), do: Process.exit(server.acceptor, :kill)
      if Process.alive?(server.state), do: Agent.stop(server.state)

      :ok
    end

    defp accept(listener, state) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          spawn(fn -> serve(socket, state) end)
          accept(listener, state)

        _error ->
          :ok
      end
    end

    defp serve(socket, state) do
      with {:ok, request} <- read_request(socket) do
        case pick_exchange(state, request) do
          nil ->
            payload = Jason.encode!(%{"error" => "conformance_unmatched_request"})

            send_response(
              socket,
              599,
              [{"content-type", "application/json"}, {"content-length", byte_size(payload)}],
              payload
            )

          respond ->
            respond(socket, respond)
        end
      end

      :gen_tcp.close(socket)
    end

    defp pick_exchange(state, request) do
      Agent.get_and_update(state, fn current ->
        found =
          current.exchanges
          |> Enum.with_index()
          |> Enum.find(fn {exchange, index} ->
            not MapSet.member?(current.consumed, index) and
              matches?(exchange["match"], request)
          end)

        requests = [request | current.requests]

        case found do
          {exchange, index} ->
            {exchange["respond"],
             %{
               current
               | consumed: MapSet.put(current.consumed, index),
                 requests: requests
             }}

          nil ->
            {nil, %{current | requests: requests, unmatched: [request | current.unmatched]}}
        end
      end)
    end

    defp matches?(match, request) do
      String.upcase(match["method"]) == request.method and
        match["path"] == request.path and
        subset?(match["query"] || %{}, request.query) and
        subset?(downcase_keys(match["headers"] || %{}), request.headers)
    end

    defp subset?(expected, actual) do
      Enum.all?(expected, fn {key, value} -> Map.get(actual, key) == value end)
    end

    defp respond(socket, %{"sse" => chunks} = response) do
      headers =
        response
        |> Map.get("headers", %{})
        |> Map.put_new("cache-control", "no-cache")
        |> Map.to_list()

      send_head(socket, response["status"], [{"transfer-encoding", "chunked"} | headers])

      Enum.each(chunks, fn chunk ->
        {delay, text} =
          if is_binary(chunk),
            do: {0, chunk},
            else: {chunk["delay_ms"] || 0, chunk["text"]}

        if delay > 0, do: Process.sleep(delay)

        if text != "" do
          :gen_tcp.send(socket, [Integer.to_string(byte_size(text), 16), "\r\n", text, "\r\n"])
        end
      end)

      if response["close"] != "abort", do: :gen_tcp.send(socket, "0\r\n\r\n")
    end

    defp respond(socket, response) do
      headers = response["headers"] || %{}

      {payload, headers} =
        cond do
          Map.has_key?(response, "json") ->
            payload = Jason.encode!(response["json"])
            {payload, Map.put_new(headers, "content-type", "application/json")}

          Map.has_key?(response, "body") ->
            {response["body"], headers}

          true ->
            {"", headers}
        end

      headers = Map.put(headers, "content-length", byte_size(payload))
      send_response(socket, response["status"], Map.to_list(headers), payload)
    end

    defp read_request(socket), do: read_headers(socket, "")

    defp read_headers(socket, buffer) do
      case :binary.match(buffer, "\r\n\r\n") do
        {index, 4} ->
          <<head::binary-size(index), _separator::binary-size(4), rest::binary>> = buffer
          [request_line | header_lines] = String.split(head, "\r\n")
          [method, target, _version] = String.split(request_line, " ", parts: 3)

          headers =
            Map.new(header_lines, fn line ->
              [key, value] = String.split(line, ":", parts: 2)
              {String.downcase(key), String.trim(value)}
            end)

          content_length = headers |> Map.get("content-length", "0") |> String.to_integer()

          with {:ok, body} <- read_body(socket, rest, content_length) do
            uri = URI.parse(target)

            {:ok,
             %{
               method: String.upcase(method),
               path: uri.path,
               query: URI.decode_query(uri.query || ""),
               headers: headers,
               body: safe_json(body)
             }}
          end

        :nomatch ->
          case :gen_tcp.recv(socket, 0, 2_000) do
            {:ok, data} -> read_headers(socket, buffer <> data)
            error -> error
          end
      end
    end

    defp read_body(_socket, body, length) when byte_size(body) >= length,
      do: {:ok, binary_part(body, 0, length)}

    defp read_body(socket, body, length) do
      with {:ok, data} <- :gen_tcp.recv(socket, length - byte_size(body), 2_000),
           do: read_body(socket, body <> data, length)
    end

    defp safe_json(""), do: nil

    defp safe_json(text) do
      case Jason.decode(text) do
        {:ok, value} -> value
        _error -> text
      end
    end

    defp send_response(socket, status, headers, body) do
      send_head(socket, status, headers)
      :gen_tcp.send(socket, body)
    end

    defp send_head(socket, status, headers) do
      reason =
        %{
          200 => "OK",
          201 => "Created",
          204 => "No Content",
          400 => "Bad Request",
          401 => "Unauthorized",
          402 => "Payment Required",
          404 => "Not Found",
          422 => "Unprocessable Entity",
          429 => "Too Many Requests",
          503 => "Service Unavailable",
          599 => "Conformance Unmatched Request"
        }[status] || "Error"

      values = [{"connection", "close"} | headers]

      head = [
        "HTTP/1.1 #{status} #{reason}\r\n",
        Enum.map(values, fn {key, value} -> "#{key}: #{value}\r\n" end),
        "\r\n"
      ]

      :gen_tcp.send(socket, head)
    end

    defp downcase_keys(map),
      do: Map.new(map, fn {key, value} -> {String.downcase(key), value} end)
  end

  for scenario <- @scenarios do
    verdict = get_in(@matrix, ["scenarios", scenario["name"], @sdk])

    if verdict != "yes" do
      @tag skip: "##{verdict["issue"]}: #{verdict["skip"]}"
    end

    test "conformance/#{scenario["name"]}" do
      scenario = unquote(Macro.escape(scenario))
      server = ScriptedServer.start(scenario["http"])

      observed = %{
        requests: [],
        unmatched: [],
        events: [],
        result: nil,
        error: nil,
        value: nil,
        event_ids: nil
      }

      observed =
        try do
          Map.merge(observed, drive(scenario, server.url))
        rescue
          error -> %{observed | error: normalise_error(error)}
        catch
          kind, reason ->
            %{observed | error: normalise_error({kind, reason})}
        after
          :ok
        end

      server_observations = ScriptedServer.observations(server)
      ScriptedServer.stop(server)
      observed = Map.merge(observed, server_observations)
      problems = check(scenario, observed)

      if problems != [] do
        flunk(
          "conformance FAILED for elixir / #{scenario["name"]}\n" <>
            "  #{scenario["title"]}\n\n" <>
            Enum.map_join(problems, "\n\n", fn problem ->
              "  " <> String.replace(problem, "\n", "\n  ")
            end)
        )
      end
    end
  end

  defp drive(scenario, base_url) do
    client_config = scenario["client"]

    client =
      Fountain.new(
        api_key: client_config["api_key"],
        base_url: base_url <> (client_config["base_url_suffix"] || ""),
        timeout: client_config["timeout_ms"] || 5_000,
        env: fn _name -> nil end,
        credentials_file: "/conformance/no-credentials"
      )

    Enum.reduce(scenario["steps"], %{}, fn step, observed ->
      drive_step(client, step, observed)
    end)
  end

  defp drive_step(client, %{"op" => "me"}, observed),
    do: Map.put(observed, :value, client |> Fountain.me() |> unwrap!())

  defp drive_step(client, %{"op" => "list", "resource" => resource}, observed) do
    value =
      case resource do
        "agents" -> Agents.list(client.agents)
        "vaults" -> Vaults.list(client.vaults)
        "environments" -> Environments.list(client.environments)
      end

    Map.put(observed, :value, unwrap!(value))
  end

  defp drive_step(client, %{"op" => "create_agent", "attrs" => attrs}, observed),
    do: Map.put(observed, :value, client.agents |> Agents.create(attrs) |> unwrap!())

  defp drive_step(
         client,
         %{"op" => "get_conversation", "conversation_id" => conversation_id},
         observed
       ) do
    value = client |> Fountain.resume(conversation_id) |> Conversation.get() |> unwrap!()
    Map.put(observed, :value, value)
  end

  defp drive_step(client, %{"op" => "history", "conversation_id" => conversation_id}, observed) do
    event_ids =
      client
      |> Fountain.resume(conversation_id)
      |> Conversation.history()
      |> unwrap!()
      |> Enum.map(& &1["id"])

    Map.put(observed, :event_ids, event_ids)
  end

  defp drive_step(
         client,
         %{"op" => "send", "conversation_id" => conversation_id, "prompt" => prompt},
         observed
       ) do
    run = client |> Fountain.resume(conversation_id) |> Conversation.send(prompt)
    result = run |> Run.await() |> unwrap!() |> normalise_result()
    Map.put(observed, :result, result)
  end

  defp drive_step(client, %{"op" => "run"} = step, observed) do
    options =
      [agent: step["agent"]]
      |> put_option(:channel_id, step["channel_id"])
      |> put_option(:client_request_id, step["client_request_id"])
      |> put_option(:timeout, step["timeout_ms"])

    run = Fountain.run(client, step["prompt"], options)
    consumer = Task.async(fn -> consume_run(run, step["answer_permissions"] || %{}) end)
    completion = Run.await(run)
    {events, _stream_error} = Task.await(consumer, :infinity)
    observed = Map.put(observed, :events, events)

    case completion do
      {:ok, result} -> Map.put(observed, :result, normalise_result(result))
      {:error, error} -> raise error
    end
  end

  defp drive_step(_client, %{"op" => operation}, _observed),
    do: raise("conformance: this adapter has no op #{operation}")

  defp consume_run(run, answers) do
    try do
      events =
        Enum.reduce(Run.stream(run), [], fn event, events ->
          if event.type == :permission do
            request_id = event.request.request_id

            case answers[request_id] || answers["*"] do
              nil -> :ok
              option_id -> run |> Run.answer(request_id, option_id) |> unwrap_answer!()
            end
          end

          [normalise_event(event) | events]
        end)

      {Enum.reverse(events), nil}
    rescue
      error -> {[], error}
    catch
      kind, reason -> {[], {kind, reason}}
    end
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)
  defp unwrap!(value), do: value

  defp unwrap_answer!(:ok), do: :ok
  defp unwrap_answer!({:ok, _value}), do: :ok
  defp unwrap_answer!({:error, error}), do: raise(error)

  defp put_option(options, _key, nil), do: options
  defp put_option(options, key, value), do: Keyword.put(options, key, value)

  defp normalise_event(%{type: :conversation} = event),
    do: %{"type" => "conversation", "conversation_id" => event.conversation_id}

  defp normalise_event(%{type: :turn_start} = event),
    do: %{
      "type" => "turn-start",
      "turn_number" => event.turn_number,
      "turn_id" => event.turn_id
    }

  defp normalise_event(%{type: type, text: text}) when type in [:text, :thinking],
    do: %{"type" => Atom.to_string(type), "text" => text}

  defp normalise_event(%{type: :tool} = event),
    do: %{"type" => "tool", "name" => event.name}

  defp normalise_event(%{type: :permission} = event),
    do: %{
      "type" => "permission",
      "request_id" => event.request.request_id,
      "options" => Enum.map(event.request.options, & &1.option_id)
    }

  defp normalise_event(%{type: :block}), do: %{"type" => "block"}
  defp normalise_event(%{type: :event}), do: %{"type" => "event"}

  defp normalise_event(%{type: :turn_end} = event),
    do: %{
      "type" => "turn-end",
      "state" => atom_string(event.state),
      "exit_code" => event.exit_code,
      "reason" => event.reason
    }

  defp normalise_event(%{type: type}), do: %{"type" => type |> atom_string() |> dash()}

  defp normalise_result(result),
    do: %{
      "state" => atom_string(result.state),
      "text" => result.text,
      "tools_used" => result.tools_used,
      "turn_number" => result.turn_number,
      "exit_code" => result.exit_code,
      "reason" => result.reason,
      "conversation_id" => result.conversation_id,
      "status" => result.status
    }

  defp normalise_error(%Error{} = error) do
    %{
      "kind" => error_kind(error.kind),
      "status" => error.status,
      "code" => error.code,
      "retryable" => Error.retryable?(error),
      "retry_after" => error.retry_after,
      "field_errors" => Error.field_errors(error),
      "upgrade_url" => Error.upgrade_url(error),
      "partial_text" => error.partial_text
    }
  end

  defp normalise_error(error) do
    %{
      "kind" => "unknown",
      "message" =>
        case error do
          {kind, reason} -> Exception.format(kind, reason)
          value -> Exception.message(value)
        end
    }
  end

  defp error_kind(:auth), do: "auth"
  defp error_kind(:not_found), do: "not_found"
  defp error_kind(:validation), do: "validation"
  defp error_kind(:rate_limit), do: "rate_limited"
  defp error_kind(:conversation_busy), do: "busy"
  defp error_kind(:quota_exceeded), do: "quota"
  defp error_kind(:insufficient_credits), do: "insufficient_credits"
  defp error_kind(:not_ready), do: "not_ready"
  defp error_kind(:timeout), do: "timeout"
  defp error_kind(:connection), do: "connection"
  defp error_kind(:resolution), do: "resolution"
  defp error_kind(:api), do: "server"
  defp error_kind(kind), do: atom_string(kind)

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: value
  defp dash(nil), do: nil
  defp dash(value), do: String.replace(value, "_", "-")

  defp check(scenario, observed) do
    expect = scenario["expect"]

    []
    |> check_unmatched(observed.unmatched)
    |> check_error(expect, observed)
    |> check_requests(expect, observed)
    |> check_events(expect, observed)
    |> check_result(expect, observed)
    |> check_value(expect, observed)
    |> check_event_ids(expect, observed)
    |> Enum.reverse()
  end

  defp check_unmatched(problems, unmatched) do
    Enum.reduce(unmatched, problems, fn request, acc ->
      [
        "unmatched request\n" <>
          "    the client sent #{request.method} #{request.path}, which no exchange in the " <>
          "scenario anticipated. Either the client should not have sent it, or the scenario " <>
          "needs it."
        | acc
      ]
    end)
  end

  defp check_error(problems, %{"error" => wanted}, %{error: nil}),
    do: ["error\n    expected #{show(wanted)} but the call succeeded" | problems]

  defp check_error(problems, %{"error" => wanted}, %{error: got}) do
    if subset?(wanted, got),
      do: problems,
      else: ["error\n    expected #{show(wanted)}\n    got #{show(got)}" | problems]
  end

  defp check_error(problems, _expect, %{error: nil}), do: problems

  defp check_error(problems, _expect, %{error: error}),
    do: ["error\n    the call was not supposed to fail, and raised #{show(error)}" | problems]

  defp check_requests(problems, %{"requests" => wanted} = expect, observed) do
    problems =
      if expect["requests_exactly"] == true and length(observed.requests) != length(wanted) do
        seen = Enum.map_join(observed.requests, ", ", &"#{&1.method} #{&1.path}")

        [
          "requests\n    expected exactly #{length(wanted)} request(s), " <>
            "saw #{length(observed.requests)}: #{seen}"
          | problems
        ]
      else
        problems
      end

    wanted
    |> Enum.with_index()
    |> Enum.reduce(problems, fn {request, index}, acc ->
      check_request(acc, request, Enum.at(observed.requests, index), index)
    end)
  end

  defp check_requests(problems, _expect, _observed), do: problems

  defp check_request(problems, wanted, nil, index),
    do: [
      "requests[#{index}]\n    expected #{wanted["method"]} #{wanted["path"]}, saw nothing"
      | problems
    ]

  defp check_request(problems, wanted, got, index) do
    if wanted["method"] != got.method or wanted["path"] != got.path do
      [
        "requests[#{index}]\n    expected #{wanted["method"]} #{wanted["path"]}, " <>
          "saw #{got.method} #{got.path}"
        | problems
      ]
    else
      problems
      |> check_request_subset("query", wanted["query"], got.query, index)
      |> check_request_subset("headers", wanted["headers"], got.headers, index)
      |> check_header_prefixes(wanted["header_prefixes"] || %{}, got.headers, index)
      |> check_headers_absent(wanted["headers_absent"] || [], got.headers, index)
      |> check_request_body(wanted["body"], got.body, index)
    end
  end

  defp check_request_subset(problems, _field, nil, _got, _index), do: problems

  defp check_request_subset(problems, field, wanted, got, index) do
    if subset?(wanted, got),
      do: problems,
      else: [
        "requests[#{index}].#{field}\n    expected #{show(wanted)}\n    got #{show(got)}"
        | problems
      ]
  end

  defp check_header_prefixes(problems, prefixes, headers, index) do
    Enum.reduce(prefixes, problems, fn {header, prefix}, acc ->
      value = headers[header] || ""

      if String.starts_with?(value, prefix) do
        acc
      else
        [
          "requests[#{index}].headers.#{header}\n" <>
            "    expected it to start with #{inspect(prefix)}, got #{inspect(value)}"
          | acc
        ]
      end
    end)
  end

  defp check_headers_absent(problems, absent, headers, index) do
    Enum.reduce(absent, problems, fn header, acc ->
      if Map.has_key?(headers, header) do
        [
          "requests[#{index}].headers.#{header}\n" <>
            "    expected no such header, got #{inspect(headers[header])}"
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp check_request_body(problems, nil, _got, _index), do: problems

  defp check_request_body(problems, wanted, got, index) do
    if deep_subset?(wanted, got),
      do: problems,
      else: [
        "requests[#{index}].body\n    expected #{show(wanted)}\n    got #{show(got)}" | problems
      ]
  end

  defp check_events(problems, %{"events" => wanted}, observed) do
    case match_event_subsequence(wanted, observed.events, 0) do
      :ok ->
        problems

      {:error, event, cursor} ->
        [
          "events\n    expected #{show(event)} after index #{cursor}, and the run emitted:\n" <>
            "    #{show(observed.events)}"
          | problems
        ]
    end
  end

  defp check_events(problems, _expect, _observed), do: problems

  defp match_event_subsequence([], _actual, _cursor), do: :ok

  defp match_event_subsequence([wanted | rest], actual, cursor) do
    case actual
         |> Enum.with_index()
         |> Enum.find(fn {got, index} -> index >= cursor and subset?(wanted, got) end) do
      nil -> {:error, wanted, cursor}
      {_event, index} -> match_event_subsequence(rest, actual, index + 1)
    end
  end

  defp check_result(problems, %{"result" => wanted}, %{result: nil}),
    do: ["result\n    expected #{show(wanted)} but there was no result" | problems]

  defp check_result(problems, %{"result" => wanted}, %{result: got}) do
    if subset?(wanted, got),
      do: problems,
      else: ["result\n    expected #{show(wanted)}\n    got #{show(got)}" | problems]
  end

  defp check_result(problems, _expect, _observed), do: problems

  defp check_value(problems, expect, observed) do
    if Map.has_key?(expect, "value") and not deep_subset?(expect["value"], observed.value),
      do: [
        "value\n    expected #{show(expect["value"])}\n    got #{show(observed.value)}" | problems
      ],
      else: problems
  end

  defp check_event_ids(problems, expect, observed) do
    if Map.has_key?(expect, "event_ids") and
         not deep_subset?(expect["event_ids"], observed.event_ids),
       do: [
         "event_ids\n    expected #{show(expect["event_ids"])}\n    got #{show(observed.event_ids)}"
         | problems
       ],
       else: problems
  end

  defp subset?(expected, actual) when is_map(expected) and is_map(actual),
    do: Enum.all?(expected, fn {key, value} -> deep_subset?(value, Map.get(actual, key)) end)

  defp subset?(_expected, _actual), do: false

  defp deep_subset?(expected, actual) when is_list(expected) do
    is_list(actual) and length(expected) == length(actual) and
      Enum.zip(expected, actual) |> Enum.all?(fn {left, right} -> deep_subset?(left, right) end)
  end

  defp deep_subset?(expected, actual) when is_map(expected) and is_map(actual),
    do: subset?(expected, actual)

  defp deep_subset?(expected, actual), do: expected == actual

  defp show(value), do: inspect(value, pretty: true, width: 90, limit: :infinity)
end
