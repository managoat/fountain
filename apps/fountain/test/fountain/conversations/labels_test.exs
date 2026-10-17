defmodule Fountain.Conversations.LabelsTest do
  @moduledoc """
  Labels on a conversation (#1637): the rule, the merge, the filter.

  The doors are covered where they live, so what is here is the behaviour
  every one of them inherits.

  """

  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Labels
  alias Fountain.Conversations.Launch

  describe "the limits" do
    test "a legal map passes" do
      assert :ok = Labels.check(%{"env" => "prod", "drift" => "true"})
      assert :ok = Labels.check(%{})
    end

    test "more than 32 entries names the key over the limit" do
      labels = for n <- 1..33, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      assert {:error, message} = Labels.check(labels)
      assert message =~ "at most 32 labels"
      assert message =~ ~s("033")
    end

    test "an over-long key names it, cut rather than echoed whole" do
      key = String.duplicate("k", 200)

      assert {:error, message} = Labels.check(%{key => "v"})
      assert message =~ "longer than 64 bytes"
      assert message =~ String.duplicate("k", 64) <> "..."
      refute message =~ String.duplicate("k", 65)
    end

    test "an over-long value names its key" do
      assert {:error, message} = Labels.check(%{"note" => String.duplicate("v", 257)})
      assert message =~ ~s("note")
      assert message =~ "longer than 256 bytes"
    end

    test "a non-string value names its key" do
      assert {:error, message} = Labels.check(%{"count" => 3})
      assert message =~ ~s("count")
      assert message =~ "string value"
    end

    test "an empty key is refused" do
      assert {:error, message} = Labels.check(%{"" => "v"})
      assert message =~ "must not be empty"
    end

    test "something that is not a map at all is refused" do
      assert {:error, _} = Labels.check(["env:prod"])
    end

    # Postgres refuses a NUL inside a jsonb string, so an unchecked one is a
    # raised Postgrex.Error rather than a refusal — a 500 on the HTTP doors
    # and a dead ConversationServer on the ACP one.
    test "a NUL byte in a value names its key" do
      assert {:error, message} = Labels.check(%{"note" => "a\u0000b"})
      assert message =~ ~s("note")
      assert message =~ "NUL byte"
    end

    test "a NUL byte in a key is refused" do
      assert {:error, message} = Labels.check(%{"a\u0000b" => "v"})
      assert message =~ "NUL byte"
    end

    test "the boundary values are legal" do
      assert :ok =
               Labels.check(%{String.duplicate("k", 64) => String.duplicate("v", 256)})

      assert :ok = Labels.check(for(n <- 1..32, into: %{}, do: {"k#{n}", "v"}))
    end

    test "an over-long key is cut to a whole codepoint, so the message stays encodable" do
      # Cutting at 64 *bytes* lands mid-character here: "é" is two bytes, so
      # byte 64 is the tail of one. A message sliced there is not valid UTF-8
      # and Jason.encode! would raise on it instead of rendering the 422.
      key = String.duplicate("é", 40)

      assert {:error, message} = Labels.check(%{key => "v"})
      assert String.valid?(message)
      assert {:ok, _} = Jason.encode(%{errors: %{labels: [message]}})
    end

    test "the same offending key is named on every run, whatever the map order" do
      labels = for n <- 1..40, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      assert {:error, first} = Labels.check(labels)
      assert {:error, second} = Labels.check(Map.new(Enum.shuffle(labels)))
      assert first == second
    end
  end

  describe "on the row" do
    setup do
      user = insert_active_user()
      {:ok, user: user}
    end

    test "a conversation created with labels reads them back", %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      assert %{"env" => "prod"} = Conversations.get_conversation(conv.id, user.id).labels
    end

    test "a conversation created without labels has an empty map", %{user: user} do
      conv = insert_conversation(user_id: user.id)

      assert %{} == Conversations.get_conversation(conv.id, user.id).labels
    end

    # The wiring, not the rule: `Conversation.changeset/2` is what every
    # writer of the column goes through, so `check/1` running from there is
    # what makes the limits inescapable rather than advisory.
    test "a plain update through the changeset is held to the limits too", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      long = String.duplicate("v", Labels.max_value_bytes() + 1)

      assert {:error, changeset} =
               Conversations.update_conversation(conv, %{labels: %{"note" => long}})

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ ~s("note")
    end

    test "the changeset refuses a write over the limits, naming the key", %{user: user} do
      conv = insert_conversation(user_id: user.id)

      assert {:error, changeset} =
               Conversations._unsafe_merge_labels(conv, %{"note" => String.duplicate("v", 300)})

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ ~s("note")
    end

    test "the count ceiling counts the merged result, not the request", %{user: user} do
      thirty_two = for n <- 1..32, into: %{}, do: {"k#{n}", "v"}
      conv = insert_conversation(user_id: user.id, labels: thirty_two)

      assert {:error, changeset} =
               Conversations._unsafe_merge_labels(conv, %{"one-too-many" => "v"})

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ "at most 32 labels"

      # And it names the key the caller sent, not whichever of the 32 already
      # on the row happens to sort into the boundary position.
      assert message =~ ~s("one-too-many")
      refute message =~ ~s("k1")
    end

    test "a write of many at once names the one that does not fit", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      labels = for n <- 1..33, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      assert {:error, changeset} = Conversations._unsafe_merge_labels(conv, labels)
      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ ~s("033")
    end

    test "a merge that only removes keys never trips the ceiling", %{user: user} do
      thirty_two = for n <- 1..32, into: %{}, do: {"k#{n}", "v"}
      conv = insert_conversation(user_id: user.id, labels: thirty_two)

      assert {:ok, updated} =
               Conversations._unsafe_merge_labels(conv, %{"k1" => nil, "new" => "v"})

      assert map_size(updated.labels) == 32
      assert updated.labels["new"] == "v"
      refute Map.has_key?(updated.labels, "k1")
    end
  end

  describe "merge" do
    test "adds and overwrites, leaves the rest alone" do
      assert %{"a" => "2", "b" => "1"} = Labels.merge(%{"a" => "1", "b" => "1"}, %{"a" => "2"})
    end

    test "a null value removes the key" do
      assert %{"b" => "1"} = Labels.merge(%{"a" => "1", "b" => "1"}, %{"a" => nil})
    end

    test "removing a key that is not there is not an error" do
      assert %{"b" => "1"} = Labels.merge(%{"b" => "1"}, %{"a" => nil})
    end

    test "changed_keys reports written and removed, sorted" do
      current = %{"a" => "1", "b" => "1", "z" => "1"}
      incoming = %{"a" => "1", "b" => "2", "c" => "3", "z" => nil, "gone" => nil}

      # "a" is unchanged so it is not written; "gone" was never there, so
      # removing it removed nothing and the trail does not claim otherwise.
      assert {["b", "c"], ["z"]} = Labels.changed_keys(current, incoming)
    end
  end

  describe "_unsafe_merge_labels/3" do
    setup do
      user = insert_active_user()
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})
      {:ok, user: user, conv: conv}
    end

    test "merges rather than replaces", %{conv: conv} do
      assert {:ok, updated} = Conversations._unsafe_merge_labels(conv, %{"drift" => "true"})
      assert updated.labels == %{"env" => "staging", "drift" => "true"}
    end

    test "a null value removes one key", %{conv: conv} do
      assert {:ok, updated} = Conversations._unsafe_merge_labels(conv, %{"env" => nil})
      assert updated.labels == %{}
    end

    test "records the keys that changed and never the values", %{user: user, conv: conv} do
      assert {:ok, _} =
               Conversations._unsafe_merge_labels(conv, %{"drift" => "true", "env" => nil})

      assert [event] =
               user.id
               |> Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))

      assert event.metadata["keys"] == ["drift"]
      assert event.metadata["removed_keys"] == ["env"]
      assert event.metadata["label_count"] == 1
      refute event.metadata |> inspect() =~ "true"
    end

    test "a merge that changes nothing writes nothing and records nothing", %{
      user: user,
      conv: conv
    } do
      assert {:ok, same} = Conversations._unsafe_merge_labels(conv, %{"env" => "staging"})
      assert same.updated_at == conv.updated_at

      assert [] =
               user.id
               |> Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))
    end
  end

  describe "set_conversation_labels/4" do
    setup do
      user = insert_active_user()
      {key, _raw} = insert_sprite_api_key(user)

      mine =
        insert_conversation(user_id: user.id, callback_api_key_id: key.id, labels: %{"a" => "1"})

      theirs = insert_conversation(user_id: user.id)

      {:ok, user: user, key: key, mine: mine, theirs: theirs}
    end

    test "the owner's own key may label any of their conversations", %{
      user: user,
      theirs: theirs
    } do
      assert {:ok, updated} =
               Conversations.set_conversation_labels(theirs.id, user.id, %{"env" => "prod"})

      assert updated.labels == %{"env" => "prod"}
    end

    test "a sandbox token may label the conversation it was minted for", %{
      user: user,
      key: key,
      mine: mine
    } do
      assert {:ok, updated} =
               Conversations.set_conversation_labels(mine.id, user.id, %{"env" => "prod"},
                 sandbox_key_id: key.id,
                 actor: "sprite"
               )

      assert updated.labels == %{"a" => "1", "env" => "prod"}
    end

    test "a sandbox token may not label another conversation", %{
      user: user,
      key: key,
      theirs: theirs
    } do
      assert {:error, :sprite_may_not_label_another_conversation} =
               Conversations.set_conversation_labels(theirs.id, user.id, %{"env" => "prod"},
                 sandbox_key_id: key.id
               )

      assert Conversations.get_conversation(theirs.id, user.id).labels == %{}
    end

    test "labels that are not a map at all are a validation failure, not a no-op", %{
      user: user,
      theirs: theirs
    } do
      assert {:error, changeset} =
               Conversations.set_conversation_labels(theirs.id, user.id, "env=prod")

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ "object of string keys"
      assert Conversations.get_conversation(theirs.id, user.id).labels == %{}
    end

    test "another tenant's conversation reads as not found", %{user: user} do
      other = insert_conversation(user_id: insert_active_user().id)

      assert {:error, :not_found} =
               Conversations.set_conversation_labels(other.id, user.id, %{"env" => "prod"})
    end
  end

  describe "labels and the rest of the row" do
    setup do
      {:ok, user: insert_active_user()}
    end

    test "an unrelated update leaves them alone", %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      assert {:ok, updated} = Conversations.update_conversation(conv, %{status: "idle"})
      assert updated.status == "idle"
      assert updated.labels == %{"env" => "prod"}
      assert Conversations.get_conversation(conv.id, user.id).labels == %{"env" => "prod"}
    end

    test "a title change leaves them alone", %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      assert {:ok, updated} = Conversations.update_conversation(conv, %{title: "renamed"})
      assert updated.labels == %{"env" => "prod"}
    end
  end

  describe "a channel resume" do
    setup do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      bound =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          status: "idle",
          channel_id: "chat:1",
          labels: %{"env" => "prod"},
          sandbox: insert_sandbox(user_id: user.id, status: "ready")
        )

      {:ok, user: user, agent: agent, bound: bound}
    end

    defp resume(context, extra) do
      Launch.start_or_resume_conversation(
        Map.merge(
          %{
            "agent_id" => context.agent.id,
            "user_id" => context.user.id,
            "channel_id" => "chat:1"
          },
          extra
        )
      )
    end

    test "merges the request's labels into the conversation it hands back", context do
      assert {:ok, conv, :resumed} = resume(context, %{"labels" => %{"run" => "17"}})
      assert conv.id == context.bound.id
      assert conv.labels == %{"env" => "prod", "run" => "17"}
    end

    test "a resume with no labels changes nothing", context do
      assert {:ok, conv, :resumed} = resume(context, %{})
      assert conv.labels == %{"env" => "prod"}
    end

    test "a null value removes a key on resume", context do
      assert {:ok, conv, :resumed} = resume(context, %{"labels" => %{"env" => nil}})
      assert conv.labels == %{}
    end

    test "a label the limits refuse fails the resume rather than being dropped", context do
      assert {:error, changeset} =
               resume(context, %{"labels" => %{"note" => String.duplicate("v", 300)}})

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ ~s("note")

      assert Conversations.get_conversation(context.bound.id, context.user.id).labels ==
               %{"env" => "prod"}
    end

    test "a sandbox token resuming a channel outside its tree finds nothing", context do
      {key, _raw} = insert_sprite_api_key(context.user)
      insert_conversation(user_id: context.user.id, callback_api_key_id: key.id)

      assert {:error, :not_found} =
               Launch.start_or_resume_conversation(
                 %{
                   "agent_id" => context.agent.id,
                   "user_id" => context.user.id,
                   "channel_id" => "chat:1",
                   "labels" => %{"run" => "17"}
                 },
                 sandbox_key_id: key.id
               )

      assert Conversations.get_conversation(context.bound.id, context.user.id).labels ==
               %{"env" => "prod"}
    end

    test "a sandbox token may not relabel a conversation it was not minted for", context do
      # In the key's tree (its child), so the resume finds it, and the labels
      # rule still refuses: a sandbox labels its own conversation only.
      {key, _raw} = insert_sprite_api_key(context.user)
      own = insert_conversation(user_id: context.user.id, callback_api_key_id: key.id)

      {:ok, _} =
        Conversations.update_conversation(context.bound, %{parent_conversation_id: own.id})

      assert {:error, :sprite_may_not_label_another_conversation} =
               Launch.start_or_resume_conversation(
                 %{
                   "agent_id" => context.agent.id,
                   "user_id" => context.user.id,
                   "channel_id" => "chat:1",
                   "labels" => %{"run" => "17"}
                 },
                 sandbox_key_id: key.id
               )

      assert Conversations.get_conversation(context.bound.id, context.user.id).labels ==
               %{"env" => "prod"}
    end
  end

  describe "the filter vocabulary" do
    test "splits on the first colon only" do
      assert {:ok, %{"path" => "a:b"}} = Labels.parse_filter(["path:a:b"])
    end

    test "combines repeated values" do
      assert {:ok, %{"env" => "prod", "drift" => "true"}} =
               Labels.parse_filter(["env:prod", "drift:true"])
    end

    test "an empty value is a legal filter" do
      assert {:ok, %{"env" => ""}} = Labels.parse_filter(["env:"])
    end

    test "a value with no colon is refused rather than guessed at" do
      assert {:error, :invalid_label_filter} = Labels.parse_filter(["prod"])
    end

    test "an empty key is refused" do
      assert {:error, :invalid_label_filter} = Labels.parse_filter([":prod"])
    end

    test "reads every repetition out of a raw query string" do
      assert ["env:prod", "drift:true"] =
               Labels.from_query_string("roots_only=true&label=env:prod&label=drift:true")
    end

    test "accepts the bracketed array form too" do
      assert ["env:prod"] = Labels.from_query_string("label%5B%5D=env%3Aprod")
    end
  end

  describe "the list filter" do
    setup do
      user = insert_active_user()

      prod_drift =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "true"})

      prod_clean =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "false"})

      staging = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})
      unlabelled = insert_conversation(user_id: user.id)

      {:ok,
       user: user,
       prod_drift: prod_drift,
       prod_clean: prod_clean,
       staging: staging,
       unlabelled: unlabelled}
    end

    defp ids(convs), do: convs |> Enum.map(& &1.id) |> MapSet.new()

    test "one pair keeps every conversation carrying it", context do
      found = Conversations.list_conversations(context.user.id, labels: %{"env" => "prod"})

      assert ids(found) == MapSet.new([context.prod_drift.id, context.prod_clean.id])
    end

    test "two pairs are combined with AND", context do
      found =
        Conversations.list_conversations(context.user.id,
          labels: %{"env" => "prod", "drift" => "true"}
        )

      assert ids(found) == MapSet.new([context.prod_drift.id])
    end

    test "a pair nothing carries matches nothing", context do
      assert [] = Conversations.list_conversations(context.user.id, labels: %{"env" => "qa"})
    end

    test "no filter leaves the list alone", context do
      assert MapSet.size(ids(Conversations.list_conversations(context.user.id))) == 4
      assert MapSet.size(ids(Conversations.list_conversations(context.user.id, labels: %{}))) == 4
    end

    test "the filter is tenant-scoped like every other", context do
      stranger = insert_active_user()
      insert_conversation(user_id: stranger.id, labels: %{"env" => "prod"})

      found = Conversations.list_conversations(context.user.id, labels: %{"env" => "prod"})
      assert ids(found) == MapSet.new([context.prod_drift.id, context.prod_clean.id])
    end

    test "combines with the other filters", context do
      agent = insert_agent(user_id: context.user.id)

      mine =
        insert_conversation(user_id: context.user.id, agent: agent, labels: %{"env" => "prod"})

      found =
        Conversations.list_conversations(context.user.id,
          agent_id: agent.id,
          labels: %{"env" => "prod"}
        )

      assert ids(found) == MapSet.new([mine.id])
    end
  end
end
