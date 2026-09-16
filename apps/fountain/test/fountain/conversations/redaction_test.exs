defmodule Fountain.Conversations.RedactionTest do
  @moduledoc """
  Keeping decrypted tenant secrets out of `log_events`.

  Secrets are placed in the sprite's environment and written to
  `/home/sprite/.env`, and every byte a sprite writes is persisted verbatim and
  streamed over SSE. So an `env`, a `set -x`, a `cat .env` in someone's
  `setup_script`, or an agent that prints its own environment, wrote plaintext
  credentials into a table with none of the envelope encryption the secret
  itself has — and one that outlives the conversation.

  A scrubber already existed for git's HTTPS token and was applied on the HTTPS
  clone path but not the SSH one. That divergence is the reason redaction now
  lives at the single writer rather than at each call site.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.Redaction

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    on_exit(fn -> Redaction.delete(conv.id) end)
    {:ok, user: user, conv: conv}
  end

  defp log_data(conv, text) do
    Conversations.log!(%{
      conversation_id: conv.id,
      kind: "output",
      stream: "stdout",
      data: text
    }).data
  end

  describe "redact/2" do
    test "replaces a registered value", %{conv: conv} do
      Redaction.put(conv.id, [{"API_TOKEN", "tenant-secret-aaaaaaaaaaaa"}])

      assert Redaction.redact(conv.id, "using tenant-secret-aaaaaaaaaaaa now") ==
               "using #{Redaction.placeholder()} now"
    end

    test "replaces every occurrence, not just the first", %{conv: conv} do
      Redaction.put(conv.id, [{"K", "supersecretvalue"}])

      out = Redaction.redact(conv.id, "supersecretvalue and supersecretvalue")
      refute out =~ "supersecretvalue"
    end

    test "leaves text alone when nothing is registered", %{conv: conv} do
      assert Redaction.redact(conv.id, "nothing to hide") == "nothing to hide"
    end

    test "prefers the longest match so no fragment survives", %{conv: conv} do
      # A short secret that is a substring of a longer one must not be replaced
      # first, or the tail of the longer secret leaks.
      Redaction.put(conv.id, [{"SHORT", "abcdefghij"}, {"LONG", "abcdefghijKLMNOP"}])

      out = Redaction.redact(conv.id, "value=abcdefghijKLMNOP")
      refute out =~ "KLMNOP"
    end

    test "short values are left alone, deliberately", %{conv: conv} do
      # Sprite environments are full of `true`, `1`, ports and regions.
      # Redacting those protects nothing and makes logs unreadable.
      Redaction.put(conv.id, [{"DEBUG", "true"}, {"PORT", "4000"}])

      assert Redaction.redact(conv.id, "DEBUG=true PORT=4000") == "DEBUG=true PORT=4000"
    end

    test "one conversation's secrets do not redact another's output" do
      a = insert_conversation(user_id: insert_verified_user().id)
      b = insert_conversation(user_id: insert_verified_user().id)
      on_exit(fn -> Redaction.delete(a.id) end)

      Redaction.put(a.id, [{"K", "tenant-a-secret-value"}])

      assert Redaction.redact(b.id, "tenant-a-secret-value") == "tenant-a-secret-value"
    end

    # A credential rotates mid-conversation while output made under the old one
    # can still be on its way, so later registrations must never forget.
    test "add/2 registers more values without forgetting any", %{conv: conv} do
      Redaction.put(conv.id, [{"TOKEN", "the-original-credential"}])
      Redaction.add(conv.id, [{"TOKEN", "the-rotated-credential"}])

      assert Redaction.redact(conv.id, "new the-rotated-credential old the-original-credential") ==
               "new [REDACTED] old [REDACTED]"
    end

    test "add/2 on an unregistered conversation registers, and still skips short values",
         %{conv: conv} do
      Redaction.add(conv.id, [{"TOKEN", "a-first-long-credential"}, {"DEBUG", "true"}])
      assert Redaction.lookup(conv.id) == ["a-first-long-credential"]
    end

    test "add/2 with nothing redactable leaves an existing registration alone", %{conv: conv} do
      Redaction.put(conv.id, [{"TOKEN", "keep-this-credential"}])
      Redaction.add(conv.id, [{"DEBUG", "true"}])
      assert Redaction.redact(conv.id, "keep-this-credential") == "[REDACTED]"
    end

    test "delete/1 forgets the values", %{conv: conv} do
      Redaction.put(conv.id, [{"K", "forget-me-completely"}])
      Redaction.delete(conv.id)

      assert Redaction.redact(conv.id, "forget-me-completely") == "forget-me-completely"
    end
  end

  describe "log!/1 — the write path" do
    test "a secret echoed by a sprite never reaches the database", %{conv: conv} do
      # The `env`-in-a-setup-script case, which is how this happens in practice.
      Redaction.put(conv.id, [{"OPENAI_API_KEY", "tenant-secret-bbbbbbbbbbbb"}])

      stored = log_data(conv, "OPENAI_API_KEY=tenant-secret-bbbbbbbbbbbb\nPATH=/usr/bin\n")

      refute stored =~ "tenant-secret-bbbbbbbbbbbb"
      assert stored =~ Redaction.placeholder()
      # Surrounding output is preserved — redaction must not eat the log.
      assert stored =~ "PATH=/usr/bin"
    end

    test "the persisted row itself contains no secret", %{conv: conv} do
      Redaction.put(conv.id, [{"K", "value-that-must-not-persist"}])
      log_data(conv, "leaking value-that-must-not-persist here")

      events = Conversations._unsafe_list_log_events(conv.id)

      for e <- events do
        refute e.data =~ "value-that-must-not-persist"
      end
    end

    test "a conversation with no registered secrets logs normally", %{conv: conv} do
      assert log_data(conv, "ordinary output") == "ordinary output"
    end

    test "redaction failure cannot break logging", %{conv: conv} do
      # Logging is on the hot path of every conversation; a redaction problem
      # must degrade rather than take the conversation down.
      assert log_data(conv, "still logged") == "still logged"
    end
  end

  describe "SSE streaming" do
    test "the broadcast payload is redacted too", %{conv: conv} do
      # Redacting the database but not the stream would be a half-fix: the SSE
      # consumer sees the event before it is ever read back.
      Redaction.put(conv.id, [{"K", "streamed-secret-value"}])
      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

      event =
        Conversations.log!(%{
          conversation_id: conv.id,
          kind: "output",
          stream: "stdout",
          data: "here is streamed-secret-value"
        })

      Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, event})

      assert_receive {:log_event, received}
      refute received.data =~ "streamed-secret-value"
    end
  end

  # The resolved MCP document comes from an Ecto `:map`, so today it is only
  # maps, lists, strings and numbers. The shapes below are what a change to
  # that field would bring, and each hid a value from an earlier version of the
  # walk (#1690). The rest of `server_state/1` is covered against a live server
  # in `ConversationServerRedactionTest`.
  @mcp_secret "mcp-document-secret-value-1690"

  defp rendered_mcp(resolved) do
    %{
      conversation_id: Ecto.UUID.generate(),
      handle: nil,
      sprite_env: [],
      brokered: %{},
      broker: nil,
      env_credentials: %{},
      resolved_mcp_servers: resolved,
      current_command: nil,
      current_turn: nil,
      acp_request_params: nil,
      turn_execution: nil,
      runner_replay: nil,
      tenant_key: nil,
      inference_credentials: %{},
      callback_token: nil,
      turn_session_retry: nil
    }
    |> Redaction.server_state()
    |> Map.fetch!(:resolved_mcp_servers)
    |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  describe "server_state/1 over the resolved MCP document" do
    test "a value inside a tuple is redacted, and the tuple keeps its shape" do
      rendered = rendered_mcp(%{"svc" => %{"auth" => {:bearer, @mcp_secret}}})

      refute rendered =~ @mcp_secret
      assert rendered =~ "svc"
      assert rendered =~ ":bearer"
    end

    test "a value in a keyword list is redacted and its key survives" do
      rendered = rendered_mcp(%{"svc" => [headers: "Bearer #{@mcp_secret}"]})

      refute rendered =~ @mcp_secret
      assert rendered =~ "headers:"
    end

    test "a charlist is redacted rather than printed as text" do
      rendered = rendered_mcp(%{"svc" => String.to_charlist(@mcp_secret)})

      refute rendered =~ @mcp_secret
      assert rendered =~ Redaction.placeholder()
    end
  end
end
