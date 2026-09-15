defmodule Fountain do
  @moduledoc """
  Official Elixir client for Fountain.

  Start a run immediately, then await its result or consume its broadcast event stream.
  """
  alias Fountain.{
    Agents,
    Client,
    Config,
    Connections,
    Conversation,
    Environments,
    HTTP,
    Resolver,
    Run,
    SSE,
    Team,
    Vaults
  }

  @doc "Builds a client. Options include `:api_key`, `:base_url`, `:app_url`, `:profile`, `:timeout`, and `:transport`."
  def new(opts \\ []) do
    config = Config.resolve(opts)
    http = HTTP.new(config, opts)
    resolver = Resolver.new(http)

    %Client{
      config: config,
      api: http,
      resolver: resolver,
      agents: Agents.new(http, resolver),
      environments: Environments.new(http, resolver),
      vaults: Vaults.new(http, resolver),
      team: Team.new(http, resolver),
      connections: Connections.new(http)
    }
  end

  @doc """
  Run a conversation request with API names and IDs, separately from local options.

  `request` uses string keys and passes values unchanged. `opts` holds local
  execution settings such as `:timeout` and `:collect_events`. This path never
  resolves names or merges the options of `run/3`. Use `Fountain.HTTP.request/4`
  for queued or promptless creation; a run follows an immediately started turn.
  """
  def run_request(%Client{} = client, request, opts \\ []) when is_map(request) do
    unless Enum.all?(Map.keys(request), &is_binary/1),
      do: raise(ArgumentError, "run_request requires string keys")

    prompt = request["prompt"]

    unless is_binary(prompt) and String.trim(prompt) != "",
      do: raise(ArgumentError, "run_request requires a non-empty prompt")

    unless request["queue"] in [nil, false],
      do: raise(ArgumentError, "run_request does not support queued creation")

    Run.new(
      client.api,
      fn ->
        response = HTTP.request!(client.api, "POST", "/api/conversations", body: request)
        conversation = response["data"]

        if get_in(response, ["meta", "resumed"]) == true do
          # Resume binds the channel without sending its prompt. Capture history
          # before submission so even a fast next turn is followed correctly.
          {:ok, after_cursor} = Conversation.cursor(resume(client, conversation["id"]))
          turn_number = next_turn_number(client.api, conversation["id"])

          HTTP.request!(client.api, "POST", "/api/conversations/#{conversation["id"]}/prompts",
            body: Map.take(request, ["prompt", "images"])
          )

          {conversation, turn_number, after_cursor}
        else
          {conversation, 1, 0}
        end
      end,
      opts
    )
  end

  @doc "Starts an agent run immediately and returns a broadcast-capable `Fountain.Run`."
  def run(%Client{} = client, prompt, opts) do
    agent = Keyword.fetch!(opts, :agent)

    Run.new(
      client.api,
      fn ->
        selected_agent = Resolver.resolve!(client.resolver, "/api/agents", "agent", agent)
        vault_id = Resolver.resolve_id!(client.resolver, "/api/vaults", "vault", opts[:vault])

        environment_id =
          Resolver.resolve_id!(
            client.resolver,
            "/api/environments",
            "environment",
            opts[:environment]
          )

        body =
          %{"agent_id" => selected_agent["id"]}
          |> optional("prompt", if(prompt == "", do: nil, else: prompt))
          |> optional("vault_id", vault_id)
          |> optional("environment_id", environment_id)
          |> optional("title", opts[:title])
          |> optional("images", nonempty(opts[:images]))
          |> optional("channel_id", opts[:channel_id])
          |> optional("fresh", if(opts[:fresh], do: true))
          |> optional("sprite_name", opts[:sprite_name])
          |> optional("sandbox_id", opts[:sandbox])
          |> optional("sandbox_mode", opts[:sandbox_mode])
          |> optional("sandbox_api_access", opts[:sandbox_api_access])

        conversation = HTTP.data!(client.api, "POST", "/api/conversations", body: body)

        turn_number =
          if opts[:channel_id], do: next_turn_number(client.api, conversation["id"]), else: 1

        {conversation, turn_number, 0}
      end,
      opts
    )
  end

  def resume(%Client{api: http}, conversation_id), do: Conversation.new(http, conversation_id)

  def conversations(%Client{api: http}, opts \\ []),
    do:
      HTTP.list(http, "/api/conversations",
        query: [roots_only: if(Keyword.get(opts, :roots_only, true), do: "true")]
      )

  def me(%Client{api: http}), do: HTTP.request(http, "GET", "/api/auth/me")
  def catalog(%Client{api: http}), do: HTTP.data(http, "GET", "/api/catalog")

  def sandboxes(%Client{api: http}, opts \\ []),
    do: HTTP.list(http, "/api/sandboxes", query: [status: join(opts[:status])])

  def sandbox(%Client{api: http}, id), do: HTTP.data(http, "GET", "/api/sandboxes/#{id}")

  def reset_sandbox(%Client{api: http}, id),
    do: void(HTTP.request(http, "DELETE", "/api/sandboxes/#{id}"))

  def sandbox_files(%Client{api: http}, id, path \\ nil),
    do: HTTP.data(http, "GET", "/api/sandboxes/#{id}/files", query: [path: path])

  def sandbox_file(%Client{api: http}, id, path, opts \\ []),
    do:
      HTTP.data(http, "GET", "/api/sandboxes/#{id}/file",
        query: [path: path, max_bytes: opts[:max_bytes]]
      )

  def sandbox_diff(%Client{api: http}, id, opts \\ []),
    do:
      HTTP.data(http, "GET", "/api/sandboxes/#{id}/diff",
        query: [
          path: opts[:path],
          staged: opts[:staged],
          ref: opts[:ref],
          max_bytes: opts[:max_bytes]
        ]
      )

  def search(%Client{api: http}, query, opts \\ []),
    do: HTTP.list(http, "/api/search", query: [q: query, limit: opts[:limit]])

  def events(%Client{api: http}, opts \\ []),
    do: SSE.stream_path(http, "/api/events/stream", Keyword.put_new(opts, :blocks, true))

  def refresh(%Client{resolver: resolver}), do: Resolver.clear(resolver)

  def request(%Client{api: http}, method, path, opts \\ []),
    do: HTTP.request(http, method, path, opts)

  def request!(%Client{api: http}, method, path, opts \\ []),
    do: HTTP.request!(http, method, path, opts)

  defp next_turn_number(http, id),
    do:
      HTTP.list!(http, "/api/conversations/#{id}/turns")
      |> Enum.reduce(0, &max(integer(&1["turn_number"]), &2))
      |> Kernel.+(1)

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0
  defp nonempty(value) when value in [nil, []], do: nil
  defp nonempty(value), do: value
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp join(value) when is_list(value), do: Enum.join(value, ",")
  defp join(value), do: value
  defp void({:ok, _}), do: :ok
  defp void(error), do: error
end
