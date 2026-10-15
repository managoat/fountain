defmodule Fountain.Conversations.SessionInfoTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.SessionInfo

  setup do
    conv = insert_conversation()
    Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{conv.user_id}")
    %{conv: conv}
  end

  defp apply_update(conv, patch) do
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => "harness-session",
          "update" => Map.put(patch, "sessionUpdate", "session_info_update")
        }
      })

    SessionInfo.apply(conv.id, line)
    Conversations._unsafe_get_conversation!(conv.id)
  end

  test "harness titles persist, refresh the sidebar, and can be revised or cleared", %{conv: conv} do
    user_id = conv.user_id

    assert %{title: "First title", title_source: "harness"} =
             apply_update(conv, %{"title" => "First title"})

    assert_receive {:sidebar_update, ^user_id}

    assert %{title: "Better title"} = apply_update(conv, %{"title" => "Better title"})
    assert_receive {:sidebar_update, ^user_id}
    assert %{title: "Better title"} = apply_update(conv, %{"updatedAt" => "2026-09-14T12:00:00Z"})
    assert %{title: "Better title"} = apply_update(conv, %{"title" => "Better title"})
    refute_received {:sidebar_update, _}

    assert %{title: nil} = apply_update(conv, %{"title" => nil})
    assert_receive {:sidebar_update, ^user_id}
    assert %{title: "New title"} = apply_update(conv, %{"title" => "New title"})
  end

  test "explicit titles stay protected, including claiming an unchanged harness title", %{
    conv: conv
  } do
    conv = apply_update(conv, %{"title" => "Harness title"})

    assert {:ok, %{title_source: "user"}} =
             Conversations.update_conversation(conv, %{title: "Harness title"})

    assert %{title: "Harness title", title_source: "user"} =
             apply_update(conv, %{"title" => "Replacement"})

    assert %{title: "Harness title"} = apply_update(conv, %{"title" => nil})

    assert {:ok, _} = Conversations.update_conversation(conv, %{title: "My title"})
    assert %{title: "My title"} = apply_update(conv, %{"title" => "Replacement"})
  end

  test "unrelated writes keep harness ownership and source cannot be set through attributes", %{
    conv: conv
  } do
    conv = apply_update(conv, %{"title" => "Harness title"})

    assert {:ok, %{title_source: "harness"}} =
             Conversations.update_conversation(conv, %{status: "idle", title_source: "user"})

    assert %{title: "Revised title"} = apply_update(conv, %{"title" => "Revised title"})
  end

  test "a rename from a stale snapshot takes ownership after a harness update", %{conv: conv} do
    apply_update(conv, %{"title" => "Harness title"})
    assert {:ok, _} = Conversations.update_conversation(conv, %{"title" => "My title"})

    assert %{title: "My title", title_source: "user"} =
             apply_update(conv, %{"title" => "Replacement"})
  end

  test "claiming a displayed title restores it if the harness has since revised it", %{conv: conv} do
    displayed = apply_update(conv, %{"title" => "Displayed title"})
    apply_update(conv, %{"title" => "New harness title"})
    assert {:ok, _} = Conversations.update_conversation(displayed, %{title: "Displayed title"})

    assert %{title: "Displayed title", title_source: "user"} =
             apply_update(conv, %{"title" => nil})
  end

  # The team channel's title guard went with the team (ADR 0074).
  test "a channel-bound conversation takes harness titles like any other", %{conv: conv} do
    {:ok, conv} = Conversations.update_conversation(conv, %{channel_id: "fountain:team"})
    assert %{title: "Harness title"} = apply_update(conv, %{"title" => "Harness title"})

    {:ok, conv} = Conversations.update_conversation(conv, %{title: "Ada"})
    assert %{title: "Ada"} = apply_update(conv, %{"title" => "Another harness title"})
  end

  test "normalizes whitespace and NULs and bounds Unicode titles to the schema limit", %{
    conv: conv
  } do
    assert %{title: "Fix login"} = apply_update(conv, %{"title" => " \nFix\0\tlogin  "})
    long_title = String.duplicate("界", 121)
    assert %{title: title} = apply_update(conv, %{"title" => long_title})
    assert title == String.duplicate("界", 120)
    assert %{title: nil} = apply_update(conv, %{"title" => " \n\t "})
  end

  test "invalid title values and unrelated or malformed notifications leave the title alone", %{
    conv: conv
  } do
    apply_update(conv, %{"title" => "Keep me"})

    for invalid <- [false, 42, %{}, []] do
      assert %{title: "Keep me"} = apply_update(conv, %{"title" => invalid})
    end

    for line <- ["not json", ~s({"method":"other","params":{"title":"Ignore me"}})] do
      assert :ok = SessionInfo.apply(conv.id, line)
    end

    assert Conversations._unsafe_get_conversation!(conv.id).title == "Keep me"
  end

  test "redacts decoded secrets before whitespace normalization or truncation", %{conv: conv} do
    secret = "private\ncredential\twith whitespace"
    long_secret = String.duplicate("sensitive-credential-", 10)
    Fountain.Conversations.Redaction.put(conv.id, [secret, long_secret])
    on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

    assert %{title: "Investigate [REDACTED]"} =
             apply_update(conv, %{"title" => "Investigate " <> secret})

    prefix = String.duplicate("x", 110)

    assert %{title: title} = apply_update(conv, %{"title" => prefix <> long_secret})
    assert title == prefix <> "[REDACTED]"
  end

  test "preserves complete graphemes within the database character limit", %{conv: conv} do
    for {grapheme, repeats} <- [{"👨‍👩‍👧‍👦", 36}, {"e\u0301\u0308", 85}] do
      assert %{title: title} = apply_update(conv, %{"title" => String.duplicate(grapheme, 120)})
      assert title == String.duplicate(grapheme, repeats)
      assert String.length(title) <= 120
      assert length(String.codepoints(title)) <= 255
    end

    oversized_grapheme = "e" <> String.duplicate("\u0301", 255)
    assert %{title: nil} = apply_update(conv, %{"title" => oversized_grapheme})
  end

  test "a deleted conversation is a no-op", %{conv: conv} do
    Repo.delete!(conv)

    assert :ok =
             SessionInfo.apply(
               conv.id,
               ~s({"method":"session/update","params":{"update":{"sessionUpdate":"session_info_update","title":"Late"}}})
             )
  end
end
