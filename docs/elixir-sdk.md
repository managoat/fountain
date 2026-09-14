# Elixir SDK

The Elixir SDK turns a conversation and its event feed into one job.

```elixir
client = Fountain.new()

run =
  Fountain.run(client, "Upgrade us to Phoenix 1.8 and open a PR",
    agent: "reposage",
    vault: "github-bot"
  )

{:ok, result} = Fountain.Run.await(run)
IO.puts(result.text)
IO.puts(result.url)
```

The source is in
[`sdk/elixir/`](https://github.com/managoat/fountain/tree/main/sdk/elixir).
It supports Elixir 1.15 and newer.

Before installation, check that `fountain_sdk 0.1.0` is available on
[Hex](https://hex.pm/packages/fountain_sdk). Then add the package to `mix.exs`.

```elixir
def deps do
  [
    {:fountain_sdk, "~> 0.1.0"}
  ]
end
```

Then fetch it.

```sh
mix deps.get
```

## Credentials

`Fountain.new()` resolves credentials in the same order as the CLI.

```text
api_key:  option -> FOUNTAIN_API_KEY -> FOUNTAIN_TOKEN -> ~/.fountain/credentials
base_url: option -> FOUNTAIN_BASE_URL -> ~/.fountain/credentials -> hosted Fountain
```

Use `Fountain.new(profile: "work")` to select another profile from the
credentials file. Inside a Fountain sandbox, the client uses the token for
that conversation. New conversations become children of the current one.

## Wait or stream

`Fountain.run/3` starts the work and returns a `Fountain.Run` handle.
`Fountain.Run.await/1` waits for the completed turn. Both operations refer to
the same run.

Use `Fountain.Run.stream/1` to read lifecycle, text, model thought, tool, block and
permission events.

```elixir
run = Fountain.run(client, "Review this repository", agent: "reviewer")

run
|> Fountain.Run.stream()
|> Enum.each(&IO.inspect/1)

{:ok, result} = Fountain.Run.await(run)
```

Use `Fountain.Run.text_stream/1` when the answer text is enough.

```elixir
run
|> Fountain.Run.text_stream()
|> Enum.each(&IO.write/1)
```

The streams are lazy `Enumerable` values. Start several runs before you
enumerate or await them to let their sandboxes provision at the same time.

A failed agent turn is a result with a failed state.

Rejected requests return error tuples. Transport failures and SDK timeouts
return the same tuple shape.

`Fountain.Run.interrupt/1` asks the agent to stop. `terminate/1` destroys its
sandbox. `cancel/1` stops only the local wait and leaves the turn active.

## Follow-up turns

Resume a conversation to send another turn to the same sandbox, checkout and
agent session.

```elixir
conversation = Fountain.resume(client, result.conversation_id)
run = Fountain.Conversation.send(conversation, "Fix the worst three.")
{:ok, next_result} = Fountain.Run.await(run)
```

## Permission requests

An agent with an `ask` permission rule stops before a tool call that matches it. Its
run emits a permission event with the options that the runtime offered. Pass
the chosen request and option identifiers back to the run.

```elixir
Fountain.Run.answer(run, request_id, option_id)
```

Another process can answer through the resumed conversation.

```elixir
conversation = Fountain.resume(client, conversation_id)
Fountain.Conversation.answer(conversation, request_id, option_id)
```

## Resources

Agents, environments and vaults have `list`, `get`, `create`, `update` and
`delete` functions. Their payloads use the API's snake-case field names.

```elixir
{:ok, environment} =
  Fountain.Environments.create(client.environments, %{
    name: "fountain-ci",
    packages: %{apt: ["ripgrep"]},
    repositories: [
      %{
        url: "https://github.com/managoat/fountain",
        mount_path: "/work/fountain"
      }
    ]
  })

{:ok, vault} = Fountain.Vaults.create(client.vaults, %{name: "github-bot"})

{:ok, _secret} =
  Fountain.Secrets.set(
    client.vaults.secrets,
    "github-bot",
    "GITHUB_TOKEN",
    token
  )

{:ok, agent} =
  Fountain.Agents.create(client.agents, %{
    name: "reposage",
    runtime: "claude",
    model: "anthropic/claude-sonnet-5",
    environment_id: environment["id"],
    allowed_vault_ids: [vault["id"]]
  })
```

Secret values are write-only. `Fountain.Secrets.list/2` returns keys and no
values. `set`, `set_all` and `delete` cover the other writes.

## The team

The team client holds named teammates, their threads and their schedules.

```elixir
{:ok, _teammate} = Fountain.Team.add(client.team, "watchtower", name: "Watchtower")
run = Fountain.Team.message(client.team, "watchtower", "Any disks over 80%?")
{:ok, reply} = Fountain.Run.await(run)
```

`Fountain.Team` also has `list`, `get`, `remove`, `rename`, `conversation`,
`history`, `fresh_conversation` and `stream` functions.
`Fountain.TeamSchedules` has the five resource functions and `run` for an
immediate schedule invocation.

## Errors and the raw API

API and transport operations return tagged tuples. Match the error struct when
the reason changes what the caller should do.

```elixir
case Fountain.Agents.get(client.agents, "reposage") do
  {:ok, agent} -> agent
  {:error, %Fountain.Error{kind: :auth}} -> raise "check the Fountain API key"
  {:error, %Fountain.Error{} = error} -> raise error
end
```

`Fountain.Error` includes `kind`, `status`, `code`, `body` and `retry_after`.
Endpoints without a resource wrapper remain available through the same client,
authentication and error behavior.

```elixir
{:ok, rows} = Fountain.request(client, :get, "/api/audit", query: [limit: 50])
```

## Release readiness

CI formats, compiles and tests the SDK. It also runs `mix hex.build`, which
checks the files and metadata that Hex will receive. A change to shipped code
must bump `@version` in `sdk/elixir/mix.exs` and add the related
`## [<version>]` heading to `sdk/elixir/CHANGELOG.md`.

CI is the only publisher. The `HEX_API_KEY` Actions secret stores the Hex key.
The key does not expire. It has API write and repository access, but does not
enter the checkout. When a shipped change reaches `main`, CI publishes
its new version and records the commit as `elixir-sdk-v<version>`. The workflow
first checks Hex, so a repeat run is safe when that version exists.

The first successful run claims the package name for the Hex account that owns
the key. Do not publish from a checkout or put the key in a file.
