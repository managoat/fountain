defmodule FountainWeb.ConversationCallTimeoutTest do
  # async: false — registers a process in the conversation registry under the
  # conversation id and lowers the global call-timeout app env.
  use FountainWeb.ConnCase, async: false

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Repo
  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Termination

  # Regression tests for #412: a GenServer.call timeout EXITS rather than
  # returning an error, and no controller or LiveView call site caught it.
  # A server stuck in handle_continue(:provision) blocks its mailbox, so
  # prompt/interrupt/terminate 500'd — and DELETE returned 500 with the row
  # silently kept, because `_ = Termination.terminate_conversation(id)` discards a
  # return value, not an exit.

  setup %{conn: conn} do
    previous_timeout = Application.fetch_env(:fountain, :conversation_call_timeout_ms)
    Application.put_env(:fountain, :conversation_call_timeout_ms, 150)

    on_exit(fn ->
      case previous_timeout do
        {:ok, value} -> Application.put_env(:fountain, :conversation_call_timeout_ms, value)
        :error -> Application.delete_env(:fountain, :conversation_call_timeout_ms)
      end
    end)

    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    conv = insert_conversation(user_id: user.id, status: "pending")

    # The shape of a server whose mailbox is blocked by provisioning:
    # registered under the conversation id, never answering calls.
    stuck =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Registry.register(Fountain.ConversationRegistry, conv.id, nil)
           Process.sleep(:infinity)
         end}
      )

    # Wait for the lookup used by the public calls, not a registration message.
    assert {:ok, ^stuck} = ConversationServer.await_registered(conv.id, 2_000)

    {:ok, conn: authed_with_key(conn, raw_key), user: user, conv: conv}
  end

  test "send_prompt during provisioning returns 503 provisioning, not a 500",
       %{conn: conn, conv: conv} do
    conn = post_json(conn, "/api/conversations/#{conv.id}/prompts", %{prompt: "hi"})

    assert %{"error" => "provisioning"} = json_response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["30"]
  end

  test "interrupt during provisioning returns 503, not a 500", %{conn: conn, conv: conv} do
    conn = post(conn, "/api/conversations/#{conv.id}/interrupt")

    assert %{"error" => "provisioning"} = json_response(conn, 503)
  end

  test "terminate during provisioning returns 503, not a 500", %{conn: conn, conv: conv} do
    conn = post(conn, "/api/conversations/#{conv.id}/terminate")

    assert %{"error" => "provisioning"} = json_response(conn, 503)
  end

  test "DELETE still deletes the row when the server does not answer",
       %{conn: conn, conv: conv} do
    # The worst pre-#412 case: the terminate exit blew through
    # delete_conversation/1 before Repo.delete ran, so the DELETE 500'd and
    # the row silently survived.
    conn = delete(conn, "/api/conversations/#{conv.id}")

    assert conn.status == 204
    assert Repo.get(Fountain.Conversations.Conversation, conv.id) == nil
  end

  test "the public functions return error tuples rather than exiting", %{conv: conv} do
    assert {:error, :provisioning} = ConversationServer.send_prompt(conv.id, "hi", [])
    assert {:error, :provisioning} = Interruption.interrupt(conv.id)
    assert {:error, :provisioning} = Termination.terminate_conversation(conv.id)
  end
end
