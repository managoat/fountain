defmodule Managoat.ACP.PlansTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.{Blocks, Plans}

  defp call(name, id, input) do
    %{"sessionUpdate" => "tool_call", "toolCallId" => id, "title" => name, "rawInput" => input}
  end

  defp result(id, output, status \\ "completed") do
    %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => id,
      "rawOutput" => output,
      "status" => status
    }
  end

  defp feed(state, update) do
    {params, state} = Plans.normalize(%{"sessionId" => "s", "update" => update}, state)
    {Blocks.from_update(params), state}
  end

  defp create(state, id, subject) do
    {[], state} = feed(state, call("TaskCreate", "create-" <> id, %{"subject" => subject}))
    feed(state, result("create-" <> id, %{"task" => %{"id" => id, "subject" => subject}}))
  end

  test "incremental tasks produce independent ordered snapshots, updates, gets and deletions" do
    {[first], state} = create(%Plans{}, "1", "Inspect")
    {[second], state} = create(state, "2", "Test")
    assert Enum.map(first.body, & &1["content"]) == ["Inspect"]
    assert Enum.map(second.body, & &1["content"]) == ["Inspect", "Test"]

    {[], state} =
      feed(state, call("TaskUpdate", "u", %{"taskId" => "1", "status" => "completed"}))

    {[updated], state} = feed(state, result("u", %{"success" => true, "taskId" => "1"}))
    assert Enum.map(updated.body, & &1["status"]) == ["completed", "pending"]
    assert hd(first.body)["status"] == "pending"
    assert state.calls == %{}

    {[], state} = feed(state, call("TaskGet", "g", %{"taskId" => "2"}))

    {[got], state} =
      feed(
        state,
        result(
          "g",
          Jason.encode!(%{
            "task" => %{"id" => "2", "subject" => "Verify", "status" => "in_progress"}
          })
        )
      )

    assert List.last(got.body)["content"] == "Verify"

    {[], state} = feed(state, call("TaskUpdate", "d", %{"taskId" => "1", "status" => "deleted"}))
    {[deleted], _} = feed(state, result("d", "Deleted task #1"))
    assert Enum.map(deleted.body, & &1["id"]) == ["2"]
  end

  test "interleaved creates use returned IDs and streamed refinements" do
    {[], state} = feed(%Plans{}, call("TaskCreate", "a", %{}))
    {[], state} = feed(state, call("TaskCreate", "b", %{"subject" => "B"}))

    {[], state} =
      feed(state, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "a",
        "rawInput" => %{"subject" => "A", "activeForm" => "Inspecting"}
      })

    {[b], state} =
      feed(
        state,
        result("b", [%{"type" => "text", "text" => "Task #20 created successfully: B"}])
      )

    {[a], _} = feed(state, result("a", "Task #10 created successfully: A"))
    assert Enum.map(b.body, & &1["id"]) == ["20"]
    assert Enum.map(a.body, & &1["id"]) == ["20", "10"]
    assert List.last(a.body)["activeForm"] == "Inspecting"
  end

  test "list replaces state, preserves known activeForm, and empty list clears it" do
    {[], state} =
      feed(%Plans{}, call("TaskCreate", "c", %{"subject" => "A", "activeForm" => "Working"}))

    {[_], state} = feed(state, result("c", %{"task" => %{"id" => "1"}}))
    {[], state} = feed(state, call("TaskList", "l", %{}))

    {[listed], state} =
      feed(
        state,
        result("l", %{"tasks" => [%{"id" => "1", "subject" => "A", "status" => "completed"}]})
      )

    assert hd(listed.body)["activeForm"] == "Working"
    {[], state} = feed(state, call("TaskList", "l2", %{}))
    {[%{body: []}], state} = feed(state, result("l2", "No tasks found"))
    assert state.tasks == []
    {[], state} = feed(state, call("TaskList", "l3", %{}))
    {[%{body: [entry]}], _} = feed(state, result("l3", "#7 [in_progress] Build"))
    assert entry["id"] == "7"
  end

  test "failed, cancelled, malformed and explicitly unsuccessful calls do not mutate state" do
    {[_], state} = create(%Plans{}, "1", "A")

    for {output, status} <- [
          {%{}, "failed"},
          {%{}, "cancelled"},
          {%{"success" => false}, "completed"},
          {%{"taskId" => "other"}, "completed"},
          {"Task #1 not found", "completed"}
        ] do
      {[], pending} =
        feed(state, call("TaskUpdate", "u", %{"taskId" => "1", "status" => "completed"}))

      {[%{kind: :tool_result}], after_call} = feed(pending, result("u", output, status))
      assert after_call.tasks == state.tasks
      assert after_call.calls == %{}
    end

    for {name, input, output} <- [
          {"TaskCreate", %{}, "unknown"},
          {"TaskGet", %{}, %{"task" => %{}}},
          {"TaskList", %{}, %{"tasks" => [nil]}},
          {"TaskList", %{}, %{"tasks" => [%{"id" => "1", "subject" => nil}]}},
          {"TaskUpdate", %{"taskId" => "unknown", "status" => "completed"}, %{}},
          {"update_plan", %{"plan" => [nil]}, %{}},
          {"TodoWrite", %{"todos" => [%{"content" => "A", "status" => "invented"}]}, %{}},
          {"TodoWrite", nil, nil}
        ] do
      {[], pending} = feed(state, call(name, "x", input))
      {[%{kind: :tool_result}], after_call} = feed(pending, result("x", output))
      assert after_call.tasks == state.tasks
    end
  end

  test "Codex and TodoWrite snapshots share the native plan block wire shape" do
    for {name, input} <- [
          {"update_plan", %{"plan" => [%{"step" => "Build", "status" => "pending"}]}},
          {"TodoWrite", %{"todos" => [%{"content" => "Build", "status" => "pending"}]}}
        ] do
      {[], state} = feed(%Plans{}, call(name, "c", Jason.encode!(input)))

      {[%{kind: :plan, body: [%{"content" => "Build", "status" => "pending"}]} = block], _} =
        feed(state, result("c", "ok"))

      assert Blocks.to_json(block)["kind"] == "plan"
      assert "plan" in Blocks.kinds()
    end
  end

  test "native plans remain authoritative without duplicate synthesized plans" do
    native = %{
      "sessionUpdate" => "plan",
      "entries" => [%{"content" => "Native", "status" => "pending", "priority" => "high"}]
    }

    {[%{body: entries}], state} = feed(%Plans{}, native)
    assert entries == native["entries"]
    {[], state} = feed(state, call("TaskCreate", "c", %{"subject" => "A"}))
    {[], _} = feed(state, result("c", %{"task" => %{"id" => "1"}}))
  end

  test "Claude metadata identifies tools without depending on their display title" do
    call =
      call("Create task: A", "c", %{"subject" => "A"})
      |> Map.put("_meta", %{"claudeCode" => %{"toolName" => "TaskCreate"}})

    {[], state} = feed(%Plans{}, call)

    hook = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "c",
      "_meta" => %{
        "claudeCode" => %{
          "toolName" => "TaskCreate",
          "toolResponse" => %{"task" => %{"id" => "1"}}
        }
      }
    }

    {[], state} = feed(state, hook)
    {[%{body: [entry]}], _} = feed(state, result("c", "ok"))
    assert entry["id"] == "1"
  end

  test "ordinary updates are unchanged and flat envelopes are supported" do
    ordinary = call("Read", "r", %{})
    assert {^ordinary, %Plans{}} = Plans.normalize(ordinary, %Plans{})

    assert {nil, %Plans{}} ==
             Plans.normalize(%{"update" => nil}, %Plans{})
             |> then(fn {params, state} -> {params["update"], state} end)

    assert Blocks.to_json(%{kind: :tool_result, error?: true, body: "oops"}) == %{
             "kind" => "tool_result",
             "error" => true,
             "body" => "oops"
           }
  end
end
