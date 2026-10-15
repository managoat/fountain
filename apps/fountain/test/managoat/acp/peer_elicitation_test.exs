defmodule Managoat.ACP.PeerElicitationTest do
  @moduledoc """
  `elicitation/create` (#2492): the form claude-agent-acp sends for its
  `AskUserQuestion` tool once the client declares form elicitation. Driven by
  hand, frame by frame, like `Managoat.ACP.PeerTest`.
  """

  use ExUnit.Case, async: true

  alias Managoat.ACP.Peer

  @declared %{
    fs: %{readTextFile: false, writeTextFile: false},
    terminal: false,
    elicitation: %{form: %{}}
  }

  # What claude-agent-acp 0.81.2's `askUserQuestionsToCreateRequest` builds
  # for two questions: one single select and one multi select, each followed
  # by its free-text "Other" field.
  @schema %{
    "type" => "object",
    "properties" => %{
      "question_0" => %{
        "type" => "string",
        "title" => "Database",
        "description" => "Which database?",
        "oneOf" => [
          %{"const" => "Postgres", "title" => "Postgres"},
          %{"const" => "SQLite", "title" => "SQLite", "description" => "File-backed"}
        ]
      },
      "question_0_custom" => %{"type" => "string", "title" => "Other"},
      "question_1" => %{
        "type" => "array",
        "title" => "Features",
        "description" => "Which features?",
        "items" => %{
          "anyOf" => [
            %{"const" => "Auth", "title" => "Auth"},
            %{"const" => "Billing", "title" => "Billing"}
          ]
        }
      },
      "question_1_custom" => %{"type" => "string", "title" => "Other"}
    }
  }

  setup do
    test = self()

    writer = fn data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end

    {:ok, ref: make_ref(), writer: writer}
  end

  defp start_peer(ctx, opts) do
    {:ok, pid} =
      Peer.start(
        [
          owner: self(),
          writer: ctx.writer,
          ref: ctx.ref,
          prompt: "do the thing",
          mode: :run,
          session_id: nil,
          cwd: "/work",
          client_capabilities: @declared
        ]
        |> Keyword.merge(opts)
      )

    pid
  end

  defp elicitation_line(id, params \\ %{}) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "elicitation/create",
      "params" =>
        Map.merge(
          %{
            "sessionId" => "sess_abc",
            "toolCallId" => "toolu_1",
            "mode" => "form",
            "message" => "Please answer the following questions.",
            "requestedSchema" => @schema
          },
          params
        )
    }) <> "\n"
  end

  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp held(ctx, id \\ 300) do
    pid = start_peer(ctx, [])
    _init = next_write()
    Peer.stdout(pid, elicitation_line(id))
    assert_receive {:acp, _ref, {:elicitation_ask, request_id, message, schema}}
    assert message == "Please answer the following questions."
    assert schema == @schema
    {pid, request_id}
  end

  test "the initialize request declares what the peer was given", ctx do
    _pid = start_peer(ctx, [])

    assert %{"method" => "initialize", "params" => %{"clientCapabilities" => caps}} =
             next_write()

    assert caps["elicitation"] == %{"form" => %{}}
  end

  test "a form is held, persisted under a minted id, and nothing is written back", ctx do
    pid = start_peer(ctx, [])
    _init = next_write()

    Peer.stdout(pid, elicitation_line(300))

    assert_receive {:acp, _ref, {:lines, "acp", line}}
    assert_receive {:acp, _ref, {:elicitation_ask, request_id, _message, _schema}}
    assert request_id =~ ~r/^300\.[0-9a-f]{16}$/
    assert %{"id" => ^request_id, "method" => "elicitation/create"} = Jason.decode!(line)

    # The block a client renders from that line.
    assert [block] = Managoat.ACP.Blocks.from_line(String.trim(line))
    assert block.kind == :elicitation_request
    assert block.request_id == request_id
    assert block.tool_id == "toolu_1"
    assert block.body == "Please answer the following questions."
    assert block.schema == @schema

    refute_receive {:wrote, _}, 50
    assert Process.alive?(pid)
  end

  test "an accepted answer is forwarded as the form's content", ctx do
    {pid, request_id} = held(ctx)

    content = %{
      "question_0" => "SQLite",
      "question_1" => ["Auth"],
      "question_1_custom" => "Search too"
    }

    assert :ok = Peer.answer_elicitation(pid, request_id, "accept", content)

    assert %{"id" => 300, "result" => %{"action" => "accept", "content" => ^content}} =
             next_write()

    # Answered once; the second is too late.
    assert {:error, :no_pending_permission} =
             Peer.answer_elicitation(pid, request_id, "decline", nil)
  end

  test "an answer that does not fit the form is refused, not forwarded", ctx do
    {pid, request_id} = held(ctx)

    assert {:error, {:invalid_content, why}} =
             Peer.answer_elicitation(pid, request_id, "accept", %{"question_0" => "MySQL"})

    assert why =~ "question_0"

    assert {:error, {:invalid_content, _}} =
             Peer.answer_elicitation(pid, request_id, "accept", %{"made_up" => "x"})

    assert {:error, {:invalid_content, _}} =
             Peer.answer_elicitation(pid, request_id, "accept", %{"question_1" => "Auth"})

    assert {:error, :unknown_action} = Peer.answer_elicitation(pid, request_id, "maybe", nil)

    refute_receive {:wrote, _}, 50

    # Still held: a fitting answer goes through.
    assert :ok = Peer.answer_elicitation(pid, request_id, "cancel", nil)
    assert %{"id" => 300, "result" => %{"action" => "cancel"}} = next_write()
  end

  test "the timeout and the turn's end decline a held form", ctx do
    {pid, request_id} = held(ctx)

    Peer.deny_permission(pid, request_id)

    assert %{"id" => 300, "result" => result} = next_write()
    assert result == %{"action" => "decline"}
  end

  test "a form is not a permission request, and the other way round", ctx do
    {pid, request_id} = held(ctx)

    assert {:error, :not_a_permission_request} = Peer.answer_permission(pid, request_id, "yes")
    refute_receive {:wrote, _}, 50
  end

  test "a peer that did not declare form elicitation refuses the method", ctx do
    pid =
      start_peer(ctx, client_capabilities: Managoat.ACP.Protocol.default_client_capabilities())

    _init = next_write()

    Peer.stdout(pid, elicitation_line(301))

    assert %{"id" => 301, "error" => %{"code" => -32_601}} = next_write()
    refute_receive {:acp, _ref, {:elicitation_ask, _, _, _}}, 50
  end

  test "a url-mode elicitation is declined at once", ctx do
    pid = start_peer(ctx, [])
    _init = next_write()

    Peer.stdout(
      pid,
      elicitation_line(302, %{
        "mode" => "url",
        "url" => "https://example.com/oauth",
        "elicitationId" => "e1"
      })
    )

    assert %{"id" => 302, "result" => %{"action" => "decline"}} = next_write()
    refute_receive {:acp, _ref, {:elicitation_ask, _, _, _}}, 50
  end

  test "a held form survives a reattach, and its replay is not raised again", ctx do
    pid =
      start_peer(ctx,
        attach: 900,
        pending_permission: %{
          "kind" => "elicitation",
          "request_id" => "303.abcdefabcdefabcd",
          "message" => "Which database?",
          "schema" => @schema
        }
      )

    Peer.stdout(pid, elicitation_line(303))
    refute_receive {:acp, _ref, {:elicitation_ask, _, _, _}}, 100

    assert {:error, {:invalid_content, _}} =
             Peer.answer_elicitation(pid, "303.abcdefabcdefabcd", "accept", %{
               "question_0" => "MySQL"
             })

    assert :ok =
             Peer.answer_elicitation(pid, "303.abcdefabcdefabcd", "accept", %{
               "question_0" => "Postgres"
             })

    assert %{"id" => 303, "result" => %{"action" => "accept"}} = next_write()
  end

  test "a form for another session is declined without being held", ctx do
    pid = start_peer(ctx, mode: :continue, session_id: "sess_mine")
    _init = next_write()

    Peer.stdout(pid, elicitation_line(304, %{"sessionId" => "sess_other"}))

    assert %{"id" => 304, "result" => %{"action" => "decline"}} = next_write()
    refute_receive {:acp, _ref, {:elicitation_ask, _, _, _}}, 50
  end
end
