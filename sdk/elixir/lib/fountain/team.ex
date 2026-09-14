defmodule Fountain.Team do
  @moduledoc "Durable teammates, their conversations, and message streams."
  alias Fountain.{Conversation, Error, HTTP, Resolver, Run, SSE}
  defstruct [:http, :resolver, :schedules]

  def new(http, resolver),
    do: %__MODULE__{
      http: http,
      resolver: resolver,
      schedules: struct(Fountain.TeamSchedules, http: http, resolver: resolver)
    }

  def list(value), do: HTTP.list(value.http, "/api/team")

  def get(value, agent),
    do:
      with(
        {:ok, id} <- agent_id(value, agent),
        do: HTTP.data(value.http, "GET", "/api/team/#{id}")
      )

  def add(value, agent, opts \\ %{}),
    do:
      with(
        {:ok, id} <- agent_id(value, agent),
        do:
          HTTP.data(value.http, "POST", "/api/team", body: Map.put(Map.new(opts), "agent_id", id))
      )

  def remove(value, agent),
    do:
      with(
        {:ok, id} <- agent_id(value, agent),
        do: void(HTTP.request(value.http, "DELETE", "/api/team/#{id}"))
      )

  def rename(value, agent, name),
    do:
      with(
        {:ok, id} <- agent_id(value, agent),
        do: HTTP.data(value.http, "PATCH", "/api/team/#{id}", body: %{"name" => name})
      )

  def message(value, agent, prompt, opts \\ []) do
    body = %{"prompt" => prompt} |> optional("images", opts[:images])

    Run.new(
      value.http,
      fn ->
        id = agent_id!(value, agent)

        before =
          case HTTP.data(value.http, "GET", "/api/team/#{id}") do
            {:ok, item} -> item
            _ -> nil
          end

        existing = get_in(before || %{}, ["conversation", "id"])

        {after_cursor, turn_number} =
          if existing do
            conversation = Conversation.new(value.http, existing)

            {ok!(Conversation.cursor(conversation)),
             ok!(Conversation.last_turn_number(conversation)) + 1}
          else
            {0, 1}
          end

        sent = HTTP.request!(value.http, "POST", "/api/team/#{id}/messages", body: body)
        conversation_id = if(is_map(sent), do: sent["conversation_id"]) || existing

        if is_nil(conversation_id),
          do:
            raise(%Error{
              message: "POST /api/team/#{id}/messages returned no conversation id",
              kind: :api
            })

        {after_cursor, turn_number} =
          if conversation_id == existing, do: {after_cursor, turn_number}, else: {0, 1}

        conversation = HTTP.data!(value.http, "GET", "/api/conversations/#{conversation_id}")
        {conversation, turn_number, after_cursor}
      end,
      opts
    )
  end

  def conversation(value, agent) do
    with {:ok, teammate} <- get(value, agent) do
      case get_in(teammate, ["conversation", "id"]) do
        nil ->
          {:error,
           %Error{
             message: "#{agent} has no conversation yet — send it a message first",
             kind: :not_found
           }}

        id ->
          {:ok, Conversation.new(value.http, id)}
      end
    end
  end

  def history(value, agent),
    do:
      with(
        {:ok, id} <- agent_id(value, agent),
        do: HTTP.list(value.http, "/api/team/#{id}/conversations")
      )

  def fresh_conversation(value, agent),
    do:
      with(
        {:ok, id} <- agent_id(value, agent),
        do: HTTP.data(value.http, "POST", "/api/team/#{id}/conversations")
      )

  def stream(value, opts \\ []),
    do: SSE.stream_path(value.http, "/api/team/stream", Keyword.put_new(opts, :blocks, true))

  defp agent_id(value, agent) do
    with {:ok, item} <- Resolver.resolve(value.resolver, "/api/agents", "agent", agent),
         do: {:ok, item["id"]}
  end

  defp agent_id!(value, agent), do: ok!(agent_id(value, agent))
  defp ok!({:ok, value}), do: value
  defp ok!({:error, error}), do: raise(error)
  defp optional(map, _key, nil), do: map
  defp optional(map, _key, []), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp void({:ok, _}), do: :ok
  defp void(error), do: error
end

defmodule Fountain.TeamSchedules do
  @moduledoc "Cron routines attached to teammates."
  alias Fountain.{HTTP, Resolver}
  defstruct [:http, :resolver]

  def list(value, agent \\ nil),
    do:
      if(agent,
        do:
          with(
            {:ok, id} <- agent_id(value, agent),
            do: HTTP.list(value.http, "/api/team/#{id}/schedules")
          ),
        else: HTTP.list(value.http, "/api/team/schedules")
      )

  def get(value, agent, id),
    do: with({:ok, path} <- path(value, agent, id), do: HTTP.data(value.http, "GET", path))

  def create(value, agent, input),
    do:
      with(
        {:ok, path} <- path(value, agent),
        do: HTTP.data(value.http, "POST", path, body: input)
      )

  def update(value, agent, id, patch),
    do:
      with(
        {:ok, path} <- path(value, agent, id),
        do: HTTP.data(value.http, "PATCH", path, body: patch)
      )

  def delete(value, agent, id),
    do:
      with(
        {:ok, path} <- path(value, agent, id),
        do: void(HTTP.request(value.http, "DELETE", path))
      )

  def run(value, agent, id),
    do:
      with(
        {:ok, path} <- path(value, agent, id),
        do: HTTP.request(value.http, "POST", path <> "/run")
      )

  defp path(value, agent, id \\ nil),
    do:
      with(
        {:ok, agent_id} <- agent_id(value, agent),
        do: {:ok, "/api/team/#{agent_id}/schedules" <> if(id, do: "/#{id}", else: "")}
      )

  defp agent_id(value, agent) do
    with {:ok, item} <- Resolver.resolve(value.resolver, "/api/agents", "agent", agent),
         do: {:ok, item["id"]}
  end

  defp void({:ok, _}), do: :ok
  defp void(error), do: error
end
