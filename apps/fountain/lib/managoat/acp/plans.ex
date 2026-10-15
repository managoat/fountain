defmodule Managoat.ACP.Plans do
  @moduledoc false

  # Session-local fallback for adapters that expose task tools instead of ACP
  # plans. Annotate the stored frame so an individual line is a complete replay
  # unit; keep the adapter's input/output available for diagnostics and tracing.
  @tools ~w(TaskCreate TaskUpdate TaskList TaskGet TodoWrite update_plan)
  @terminal ~w(completed failed cancelled)

  defstruct tasks: [], calls: %{}, native?: false

  def normalize(params, state) do
    update = Map.get(params, "update", params)
    {update, state} = normalize_update(update, state)

    params =
      if Map.has_key?(params, "update"), do: Map.put(params, "update", update), else: update

    {params, state}
  end

  def tool_name(update) do
    meta = claude_meta(update)["toolName"]
    Enum.find([meta, update["name"], update["title"]], &(&1 in @tools))
  end

  defp normalize_update(%{"sessionUpdate" => "plan", "entries" => entries} = update, state)
       when is_list(entries) do
    {update, %{state | native?: true}}
  end

  defp normalize_update(%{"sessionUpdate" => variant, "toolCallId" => id} = update, state)
       when variant in ["tool_call", "tool_call_update"] and is_binary(id) do
    previous = Map.get(state.calls, id, %{})
    call = Map.merge(previous, update)
    meta = Map.merge(claude_meta(previous), claude_meta(update))
    call = Map.put(call, "_meta", Map.put(object(call["_meta"]), "claudeCode", meta))

    case tool_name(call) do
      nil -> {update, state}
      name -> normalize_call(update, call, name, id, state)
    end
  end

  defp normalize_update(update, state), do: {update, state}

  defp normalize_call(update, call, name, id, state) do
    if call["status"] in @terminal do
      state = %{state | calls: Map.delete(state.calls, id)}
      finish(update, call, name, state)
    else
      {annotate(update, nil), %{state | calls: Map.put(state.calls, id, call)}}
    end
  end

  defp finish(update, %{"status" => "completed"} = call, name, state) do
    input = object(call["rawInput"])
    output = output(call)

    case apply_call(name, input, output, state.tasks) do
      {:ok, tasks} ->
        entries = if state.native?, do: nil, else: tasks
        {annotate(update, entries), %{state | tasks: tasks}}

      :error ->
        # An unreadable result is not evidence that a task was created or
        # deleted. Keep the result visible rather than inventing a checklist.
        {update, state}
    end
  end

  defp finish(update, _call, _name, state), do: {update, state}

  defp annotate(update, entries) do
    meta = object(update["_meta"])
    Map.put(update, "_meta", Map.put(meta, "managoat_acp", %{"plan" => entries}))
  end

  defp apply_call("update_plan", %{"plan" => entries}, _, _) when is_list(entries) do
    snapshot(entries, "step")
  end

  defp apply_call("TodoWrite", %{"todos" => entries}, _, _) when is_list(entries) do
    snapshot(entries, "content")
  end

  defp apply_call("TaskList", _, %{"tasks" => tasks}, known) when is_list(tasks) do
    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, acc} ->
      case upsert(known, task) do
        {:ok, updated} ->
          entry = Enum.find(updated, &(&1["id"] == task["id"]))
          {:cont, {:ok, acc ++ [entry]}}

        :error ->
          {:halt, :error}
      end
    end)
  end

  defp apply_call(name, input, %{"task" => task}, tasks)
       when name in ["TaskCreate", "TaskGet"] and is_map(task) do
    if name == "TaskGet" and input["taskId"] not in [nil, task["id"]] do
      :error
    else
      upsert(tasks, Map.merge(input, task))
    end
  end

  defp apply_call("TaskUpdate", %{"taskId" => id} = input, output, tasks) when is_binary(id) do
    cond do
      output["success"] == false -> :error
      output["taskId"] not in [nil, id] -> :error
      input["status"] == "deleted" -> {:ok, Enum.reject(tasks, &(&1["id"] == id))}
      true -> upsert(tasks, Map.put(input, "id", id))
    end
  end

  defp apply_call(_, _, _, _), do: :error

  defp snapshot(entries, content_key) do
    entries
    |> Enum.map(fn
      entry when is_map(entry) -> Map.put(entry, "content", entry[content_key])
      entry -> entry
    end)
    |> validate_entries()
  end

  defp validate_entries(entries) do
    if Enum.all?(entries, &valid_entry?/1) do
      {:ok, Enum.map(entries, &Map.take(&1, ~w(id content status priority activeForm)))}
    else
      :error
    end
  end

  defp valid_entry?(%{"content" => content, "status" => status}) do
    is_binary(content) and status in ~w(pending in_progress completed)
  end

  defp valid_entry?(_), do: false

  defp upsert(tasks, %{"id" => id} = task) when is_binary(id) and id != "" do
    existing = Enum.find(tasks, %{}, &(&1["id"] == id))

    entry =
      existing
      |> Map.merge(Map.take(task, ~w(id activeForm)))
      |> Map.put("content", Map.get(task, "subject", existing["content"]))
      |> Map.put("status", Map.get(task, "status", Map.get(existing, "status", "pending")))
      |> Map.put("priority", "medium")

    cond do
      not valid_entry?(entry) -> :error
      existing == %{} -> {:ok, tasks ++ [entry]}
      true -> {:ok, Enum.map(tasks, fn old -> if old["id"] == id, do: entry, else: old end)}
    end
  end

  defp upsert(_, _), do: :error

  defp object(value) when is_map(value), do: value

  defp object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp object(_), do: %{}

  defp claude_meta(update), do: update["_meta"] |> object() |> Map.get("claudeCode") |> object()

  defp output(call) do
    structured = claude_meta(call)["toolResponse"]
    raw = call["rawOutput"] || call["content"]
    decoded = object(structured || raw)
    if decoded == %{}, do: text_output(output_text(raw)), else: decoded
  end

  defp output_text(value) when is_binary(value), do: value
  defp output_text(values) when is_list(values), do: Enum.map_join(values, "\n", &output_text/1)
  defp output_text(%{"type" => "content", "content" => content}), do: output_text(content)
  defp output_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp output_text(_), do: ""

  defp text_output(text) do
    case object(text) do
      map when map_size(map) > 0 -> map
      _ -> task_text(String.trim(text))
    end
  end

  defp task_text("No tasks found"), do: %{"tasks" => []}

  defp task_text(text) do
    cond do
      match = Regex.run(~r/^Task #(\S+) created successfully: (.+)$/s, text) ->
        [_, id, subject] = match
        %{"task" => %{"id" => id, "subject" => subject}}

      Regex.match?(~r/^Task #\S+ not found$|^Failed to delete task$/, text) ->
        %{"success" => false}

      true ->
        listed_tasks(text)
    end
  end

  defp listed_tasks(text) do
    tasks =
      text
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Regex.run(~r/^#(\S+) \[(pending|in_progress|completed)\] (.+)$/, line) do
          [_, id, status, subject] -> %{"id" => id, "status" => status, "subject" => subject}
          _ -> nil
        end
      end)

    if tasks != [] and Enum.all?(tasks, &is_map/1), do: %{"tasks" => tasks}, else: %{}
  end
end
