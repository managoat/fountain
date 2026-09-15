# Fountain Elixir SDK

The official Elixir client for [Fountain](https://github.com/managoat/fountain). It covers agent runs and follow-ups, reconnecting event streams, permission requests, resources and secrets, teammates and schedules, connections, conversation history, and sandbox lifecycle/files.

## Installation

Add `fountain_sdk` to `mix.exs`:

```elixir
def deps do
  [{:fountain_sdk, "~> 0.4.0"}]
end
```

Elixir 1.15 or newer is required.

## Authentication

The client resolves credentials the same way as the Fountain CLI:

1. Explicit `:api_key` and `:base_url` options
2. `FOUNTAIN_API_KEY` (or sandbox-scoped `FOUNTAIN_TOKEN`) and `FOUNTAIN_BASE_URL`
3. The selected profile in `~/.fountain/credentials`
4. The hosted Fountain endpoint

```elixir
client = Fountain.new(api_key: System.fetch_env!("FOUNTAIN_API_KEY"))
```

When code runs inside a Fountain sandbox, `FOUNTAIN_CONVERSATION_ID` is automatically sent as parent attribution. HTTPS uses peer and hostname verification with the Erlang/OTP CA store.

## Run an agent

Pass `sandbox_api_access: "none", sandbox_mode: "ephemeral"` to `Fountain.run/3`
to start without an owner callback credential in the sandbox. Omitting
`:sandbox_api_access` inherits a resumed channel's setting; new conversations
default to `"owner"`.

`Fountain.run/3` starts work immediately. The handle supports one completion wait and any number of event consumers without making a second API request.

```elixir
client = Fountain.new()

run =
  Fountain.run(client, "Upgrade us to Phoenix 1.8 and open a PR",
    agent: "reposage",
    vault: "github-bot"
  )

{:ok, result} = Fountain.Run.await(run)
IO.puts(result.text)
IO.inspect(result.tools_used)
```

Set `timeout: milliseconds` on `Fountain.run/3`, `Fountain.Conversation.send/3`, or `Fountain.Team.message/4` to stop the SDK waiting. A timeout does not interrupt the remote turn; the returned `%Fountain.Error{kind: :timeout}` contains `conversation_id` and `partial_text` so it can be resumed.

Stream all derived and raw events, or only answer text:

```elixir
for event <- Fountain.Run.stream(run), do: IO.inspect(event)
for text <- Fountain.Run.text_stream(run), do: IO.write(text)
```

Run events use idiomatic atom keys and `:conversation`, `:turn_start`, `:text`, `:thinking`, `:tool`, `:permission`, `:block`, `:event`, and `:turn_end` types. Raw API payloads remain string-keyed maps.

### Permissions and control

```elixir
for %{type: :permission, request: request} <- Fountain.Run.stream(run) do
  allow = Enum.find(request.options, &(&1["kind"] == "allow_once"))
  if allow, do: Fountain.Run.answer(run, request.request_id, allow.option_id)
end

Fountain.Run.interrupt(run) # stop the turn; keep the sandbox
Fountain.Run.terminate(run) # tear the sandbox down
Fountain.Run.cancel(run)    # stop only this SDK wait
```

## Follow up and inspect conversations

```elixir
conversation = Fountain.resume(client, result.conversation_id)
follow_up = Fountain.Conversation.send(conversation, "Now add regression tests")
{:ok, next_result} = Fountain.Run.await(follow_up)

{:ok, history} = Fountain.Conversation.history(conversation, streams: [:acp])
{:ok, turns} = Fountain.Conversation.turns(conversation)
:ok = Fountain.Conversation.mark_read(conversation)
```

`history/2` drains every page and requests server-parsed blocks. `events/2` returns the raw reconnecting SSE enumerable. Follow-ups discover the end of a cold conversation's stage feed before posting, preventing old output from being replayed as the new answer.

Conversation handles also provide `get/1`, `status/1`, `tree/1`, `event_page/3`, `answer/3`, `interrupt/1`, `terminate/1`, and `delete/1`.

## Resources and secrets

The client exposes resource handles directly:

```elixir
{:ok, agents} = Fountain.Agents.list(client.agents)
{:ok, agent} = Fountain.Agents.get(client.agents, "reposage")
{:ok, created} = Fountain.Environments.create(client.environments, environment_definition)

:ok = Fountain.Secrets.delete(client.environments.secrets, "production", "OLD_TOKEN")
{:ok, _} = Fountain.Secrets.set(client.vaults.secrets, "github-bot", "GITHUB_TOKEN", token)
```

`Fountain.Agents`, `Fountain.Environments`, and `Fountain.Vaults` implement `list`, `get`, `create`, `update`, and `delete`. Names resolve case-insensitively, then by unique prefix; UUIDs skip a listing. Resource payloads use the API's string keys so definitions can be shared with REST and `fountain.yml`.

## Teammates and schedules

```elixir
{:ok, teammates} = Fountain.Team.list(client.team)
run = Fountain.Team.message(client.team, "reviewer", "Review the latest PR")

{:ok, schedule} =
  Fountain.TeamSchedules.create(client.team.schedules, "reviewer", %{
    "cron" => "0 9 * * 1-5",
    "prompt" => "Review open pull requests"
  })
```

`Fountain.Team` includes `list`, `get`, `add`, `remove`, `rename`, `message`, `conversation`, `history`, `fresh_conversation`, and `stream`. `Fountain.TeamSchedules` includes `list`, `get`, `create`, `update`, `delete`, and `run`.

## Connections and sandboxes

Provider connections are available at `client.connections`; provider definitions are at `client.connections.providers`.

```elixir
{:ok, connections} = Fountain.Connections.list(client.connections)
{:ok, providers} = Fountain.ConnectionProviders.list(client.connections.providers)

{:ok, sandboxes} = Fountain.sandboxes(client, status: ["ready", "suspended"])
{:ok, listing} = Fountain.sandbox_files(client, sandbox_id, "src")
{:ok, file} = Fountain.sandbox_file(client, sandbox_id, "mix.exs", max_bytes: 64_000)
{:ok, diff} = Fountain.sandbox_diff(client, sandbox_id, staged: true)
:ok = Fountain.reset_sandbox(client, sandbox_id)
```

Connections support `list`, `get`, and `delete`. Providers support `list`, `get`, `create`, `update`, `delete`, and MCP `discover`.

## Errors and raw requests

All non-bang public calls return `{:ok, value}`, `:ok`, or `{:error, %Fountain.Error{}}`. Errors expose `kind`, HTTP `status`, server `code`, parsed `body`, and `retry_after`. Helpers include `Fountain.Error.retryable?/1` and `field_errors/1`.

```elixir
case Fountain.request(client, "GET", "/api/new-endpoint") do
  {:ok, body} -> body
  {:error, %Fountain.Error{kind: :rate_limit, retry_after: seconds}} -> {:retry, seconds}
end
```

Absolute URLs are accepted only when they have the configured Fountain origin, preventing bearer credentials from being sent cross-origin.

## Process ownership

A client resolver cache, conversation cursor, and run server are lightweight process-owned state. Create and use handles from a long-lived process (such as a GenServer) when sharing them. A run and its active HTTP/SSE work are cleaned up when the process that created it exits.

## License

Apache-2.0. See [LICENSE](LICENSE).

## Credit error migration (0.3.0)

Replace `%Fountain.Error{kind: :subscription_required}` patterns with
`%Fountain.Error{kind: :insufficient_credits}`. Read `Fountain.Error.upgrade_url(error)`
to offer the credit-purchase page; do not retry a 402 without adding credit.

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.

### API-shaped launches

```elixir
Fountain.run_request(client, %{
  "agent_id" => agent_id,
  "prompt" => "Review the repository",
  "labels" => %{"source" => "nightly"},
  "sandbox_api_access" => "none"
}, timeout: 120_000, collect_events: true)
|> Fountain.Run.await()
```

The request uses string keys and IDs directly; atom keys at its top level are
refused rather than converted or merged. Explicit nil, false, zero and empty
values survive; omitted keys remain omitted. Local options stay in the third
argument. No names are resolved and no legacy run options are merged into the
request; existing `Fountain.run/3` calls keep working. A run requires a non-empty
prompt and cannot queue. Use the HTTP client for promptless or queued creation.

With `channel_id`, `run_request` follows turn 1 when the server creates a
conversation, including fresh launches. When the server resumes a channel,
it submits the prompt and images to that conversation and follows the next turn.
