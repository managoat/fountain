defmodule Fountain.Conversation do
  @moduledoc """
  A resumable conversation and its persistent sandbox session.

  Its cursor is an `:atomics` reference: shared across processes like the ETS
  table it replaced, but reclaimed with the handle. A table would have been
  owned by the creating process, so a long-lived caller that resumes a
  conversation per inbound message leaked one table per call.
  """
  alias Fountain.{Config, HTTP, Run, SSE}
  defstruct [:http, :id, :cursor]

  def new(http, id, cursor \\ 0) do
    ref = :atomics.new(1, signed: false)
    if is_integer(cursor) and cursor > 0, do: :atomics.put(ref, 1, cursor)
    %__MODULE__{http: http, id: id, cursor: ref}
  end

  def url(value), do: Config.conversation_url(value.id, value.http.config)
  def get(value), do: HTTP.data(value.http, "GET", "/api/conversations/#{value.id}")
  def status(value), do: with({:ok, record} <- get(value), do: {:ok, record["status"]})
  def turns(value), do: HTTP.list(value.http, "/api/conversations/#{value.id}/turns")

  @doc """
  Sends a follow-up prompt. Cursor and turn number are captured before POST.

  `:client_request_id` is the caller's own name for this submission. It is
  carried to the turn the prompt opens and onto that turn's `started` event
  (#1406), so the caller reads back which turn was its own rather than
  guessing from turn order. It is not an idempotency key: the same value sent
  twice opens two turns.
  """
  def send(value, prompt, opts \\ []) do
    body =
      %{"prompt" => prompt}
      |> optional("images", opts[:images])
      |> optional("client_request_id", opts[:client_request_id])

    run =
      Run.new(
        value.http,
        fn ->
          after_cursor = cursor!(value)
          turn_number = last_turn_number!(value) + 1
          HTTP.request!(value.http, "POST", "/api/conversations/#{value.id}/prompts", body: body)
          conversation = HTTP.data!(value.http, "GET", "/api/conversations/#{value.id}")
          {conversation, turn_number, after_cursor}
        end,
        opts
      )

    watch_cursor(value, run)

    run
  end

  # Advancing the cursor is bookkeeping nobody awaits, so it is supervised
  # rather than linked, and both calls tolerate the run server going away: when
  # the handle's owner exits first the server stops `:normal`, and an unguarded
  # `GenServer.call` would then take this process down with a crash report for a
  # write no caller wants. The TypeScript client swallows the same rejection.
  defp watch_cursor(value, run) do
    Task.Supervisor.start_child(FountainSdk.TaskSupervisor, fn ->
      try do
        _ = Run.await(run)
        update_cursor_value(value, Run.cursor(run))
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok
  end

  def answer(value, request_id, option_id),
    do:
      void(
        HTTP.request(
          value.http,
          "POST",
          "/api/conversations/#{value.id}/requests/#{escape(request_id)}",
          body: %{"option_id" => option_id}
        )
      )

  def mark_read(value),
    do: void(HTTP.request(value.http, "POST", "/api/conversations/#{value.id}/read"))

  def interrupt(value),
    do: void(HTTP.request(value.http, "POST", "/api/conversations/#{value.id}/interrupt"))

  def terminate(value),
    do: void(HTTP.request(value.http, "POST", "/api/conversations/#{value.id}/terminate"))

  def delete(value),
    do: void(HTTP.request(value.http, "DELETE", "/api/conversations/#{value.id}"))

  def tree(value), do: HTTP.data(value.http, "GET", "/api/conversations/#{value.id}/tree")

  @doc """
  Reapply this conversation's agent, environment and vault in place.

  The machine, the transcript and the files on disk all stay. An option that
  is not given keeps its current selection; `nil` clears the environment
  override or the vault. Called with no options it reapplies what is already
  selected.
  """
  def reapply(value, opts \\ []) do
    body =
      [:agent_id, :environment_id, :vault_id]
      |> Enum.reduce(%{}, fn key, acc ->
        if Keyword.has_key?(opts, key),
          do: Map.put(acc, Atom.to_string(key), Keyword.get(opts, key)),
          else: acc
      end)

    HTTP.data(value.http, "POST", "/api/conversations/#{value.id}/reapply", body: body)
  end

  @doc "Fetches all history pages, requesting server-parsed blocks."
  def history(value, opts \\ []),
    do:
      history_pages(
        value,
        Keyword.get(opts, :after, 0),
        Keyword.get(opts, :limit, 1000),
        streams(opts[:streams]),
        []
      )

  defp history_pages(value, after_cursor, limit, streams, acc) do
    with {:ok, page} <-
           HTTP.request(value.http, "GET", "/api/conversations/#{value.id}/events",
             query: [after: after_cursor, limit: limit, blocks: "true", streams: streams]
           ) do
      events = if is_map(page) and is_list(page["data"]), do: page["data"], else: []
      meta = if is_map(page), do: page["meta"] || %{}, else: %{}
      all = acc ++ events

      if meta["has_more"] && is_integer(meta["next_cursor"]) do
        history_pages(value, meta["next_cursor"], limit, streams, all)
      else
        update_cursor(value, all)
        {:ok, all}
      end
    end
  end

  def events(value, opts \\ []), do: SSE.stream_events(value.http, value.id, opts)

  def event_page(value, after_cursor \\ 0, limit \\ 1000) do
    with {:ok, page} <-
           HTTP.request(value.http, "GET", "/api/conversations/#{value.id}/events",
             query: [after: after_cursor, limit: limit, blocks: "true"]
           ) do
      meta = if is_map(page), do: page["meta"] || %{}, else: %{}

      {:ok,
       %{
         events: page["data"] || [],
         next_cursor:
           if(is_integer(meta["next_cursor"]), do: meta["next_cursor"], else: after_cursor),
         has_more: !!meta["has_more"]
       }}
    end
  end

  def last_turn_number(value) do
    with {:ok, turns} <- turns(value),
         do: {:ok, Enum.reduce(turns, 0, &max(integer(&1["turn_number"]), &2))}
  end

  def cursor(value) do
    case :atomics.get(value.cursor, 1) do
      cursor when cursor > 0 -> {:ok, cursor}
      _ -> discover_cursor(value)
    end
  end

  defp discover_cursor(value) do
    try do
      cursor =
        value
        |> events(streams: "stage", wait: false, max_retries: 0)
        |> Enum.reduce(0, fn event, acc ->
          if is_integer(event["id"]), do: max(acc, event["id"]), else: acc
        end)

      update_cursor_value(value, cursor)
      {:ok, cursor}
    rescue
      _ -> {:ok, 0}
    end
  end

  defp cursor!(value) do
    {:ok, cursor} = cursor(value)
    cursor
  end

  defp last_turn_number!(value) do
    case last_turn_number(value) do
      {:ok, number} -> number
      {:error, error} -> raise error
    end
  end

  defp update_cursor(_value, []), do: :ok

  defp update_cursor(value, events) do
    id = events |> List.last() |> then(& &1["id"])
    if is_integer(id), do: update_cursor_value(value, id)
  end

  # The cursor only moves forward, and two turns on one handle can report at
  # once, so the bump is a compare-exchange rather than a read-then-write.
  defp update_cursor_value(value, id) when is_integer(id) and id > 0 do
    current = :atomics.get(value.cursor, 1)

    if id > current do
      case :atomics.compare_exchange(value.cursor, 1, current, id) do
        :ok -> :ok
        _raced -> update_cursor_value(value, id)
      end
    else
      :ok
    end
  end

  defp update_cursor_value(_value, _id), do: :ok

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> 0
    end
  end

  defp integer(_), do: 0
  defp streams(value) when is_list(value), do: Enum.join(value, ",")
  defp streams(value), do: value
  defp optional(map, _key, nil), do: map
  defp optional(map, _key, []), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp escape(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
  defp void({:ok, _}), do: :ok
  defp void(error), do: error
end
