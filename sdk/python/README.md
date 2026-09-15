# fountain-agent-sdk

Give an agent a computer, your repositories, and your credentials in one call.

```python
from fountain import Fountain

fountain = Fountain()
result = fountain.run(
    "Upgrade us to Phoenix 1.8 and open a PR",
    agent="reposage",
    vault="github-bot",
).result()

print(result.text)
print(result.url)
```

The agent runs on a real sandbox with the selected environment and vault. The
sandbox remains after the turn, so a follow-up continues on the same computer
and in the same agent session.

## Install

```bash
pip install fountain-agent-sdk
```

Python 3.9 or newer. The SDK has no runtime dependencies.

## Credentials

`Fountain()` resolves credentials the same way as the Fountain CLI:

```text
api_key:  argument -> FOUNTAIN_API_KEY -> FOUNTAIN_TOKEN -> ~/.fountain/credentials
base_url: argument -> FOUNTAIN_BASE_URL -> ~/.fountain/credentials -> hosted Fountain
```

Use `profile="work"` to select another credentials-file profile. A client in a
Fountain sandbox automatically uses its conversation-scoped token and marks
the work it creates as child conversations.

## Wait, stream, or fan out

Pass `sandbox_api_access="none", sandbox_mode="ephemeral"` to `run()` to start
without an owner callback credential in the sandbox. Omit `sandbox_api_access`
to inherit a resumed channel's setting; new conversations default to `"owner"`.

`run()` starts work immediately in a background thread. Calling `result()`
waits for the finished turn. Iterating the same handle streams its events.

```python
run = fountain.run("Review this repository", agent="reviewer")

for event in run:
    if event["type"] == "tool":
        print("->", event["name"])
    elif event["type"] == "text":
        print(event["text"], end="", flush=True)

result = run.result()  # this is the same run; no second request is made
```

For only the answer text:

```python
run = fountain.run("Review this repository", agent="reviewer")
for chunk in run.text_stream:
    print(chunk, end="", flush=True)
```

The same handle also works in asyncio code. HTTP still runs in the SDK's
background thread, so it does not block the event loop.

```python
result = await fountain.run("Review this repository", agent="reviewer")

run = fountain.run("Review another repository", agent="reviewer")
async for event in run:
    print(event)
```

Start several handles before collecting them to provision their sandboxes in
parallel:

```python
runs = [fountain.run(prompt, agent=agent) for agent in agents]
results = [run.result() for run in runs]
```

A failed agent turn is a `RunResult` with `state == "failed"`. Rejected HTTP
requests, transport failures, and SDK wait timeouts raise typed exceptions.

## Follow-ups and permissions

```python
first = fountain.run("Find every N+1 query", agent="reposage").result()
second = fountain.resume(first.conversation_id).send("Fix the worst three.").result()
```

An agent with an `ask` permission policy emits permission events. Answer with
one of the option ids it offered:

```python
run = fountain.run("Clean the build tree", agent="reposage")
for event in run:
    if event["type"] != "permission":
        continue
    request = event["request"]
    allow = next(option for option in request["options"] if option.get("kind") == "allow_once")
    run.answer(request["request_id"], allow["option_id"])
```

## Resources and teammates

Resource definitions use the API's snake_case keys, so the same dictionary can
also appear in a `fountain.yml` manifest or raw REST request.

```python
environment = fountain.environments.create({
    "name": "fountain-ci",
    "packages": {"apt": ["ripgrep"]},
    "repositories": [{
        "url": "https://github.com/managoat/fountain",
        "mount_path": "/work/fountain",
    }],
})

vault = fountain.vaults.create({"name": "github-bot"})
fountain.vaults.secrets.set("github-bot", "GITHUB_TOKEN", token)

agent = fountain.agents.create({
    "name": "reposage",
    "runtime": "claude",
    "model": "anthropic/claude-sonnet-5",
    "environment_id": environment["id"],
    "allowed_vault_ids": [vault["id"]],
})
```

Agents, environments, and vaults each have `list`, `get`, `create`, `update`,
and `delete`. Environments and vaults also have write-only `secrets` helpers.

```python
fountain.team.add("watchtower", name="Watchtower")
reply = fountain.team.message("watchtower", "Any disks over 80%?").result()
fountain.team.schedules.create("watchtower", {
    "cron": "0 9 * * *",
    "prompt": "Check disk usage and say only what changed.",
})
```

## Cancel a wait

`run.cancel()` stops the local wait and skips the final status request. The
agent continues its work. A silent stream can delay cancellation by up to
five seconds. Idle reads reconnect from the last complete event.

A custom HTTP transport must honor the supplied socket timeout.

## Raw API and errors

Every endpoint remains available through the authenticated HTTP layer:

```python
rows = fountain.request("GET", "/api/audit", query={"limit": 50})
```

Catch subclasses such as `ConversationBusyError`, `NotReadyError`,
`QuotaExceededError`, `ValidationError`, and `AuthError`. Every
`FountainError` carries `status`, `code`, `body`, `retry_after`, and a
`retryable` property.

## Develop

```bash
python3 -m unittest discover -s tests -v
python3 -m pip wheel . --no-deps
```

## Credit error migration (0.3.0)

Replace `SubscriptionRequiredError` imports and `except` clauses with
`InsufficientCreditsError`. The old export is removed. Read `error.upgrade_url`
to offer the credit-purchase page; do not retry a 402 without adding credit.

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.

### API-shaped launches

```python
result = client.run_request({
    "agent_id": agent_id,
    "prompt": "Review the repository",
    "labels": {"source": "nightly"},
    "sandbox_api_access": "none",
}, timeout=120, collect_events=True).result()
```

`run_request` forwards the mapping's API names and IDs directly. Explicit
`None`, `False`, zero and empty values survive; absent keys remain absent.
Timeout and event collection are local keyword arguments, outside the request.
This path never resolves names or merges legacy `run` keywords; existing
`run(prompt, agent=...)` calls retain their behavior. A non-empty prompt is
required and queued starts are refused before HTTP. Use `client.request` for
promptless or queued conversation creation.

With `channel_id`, `run_request` follows turn 1 when the server creates a
conversation, including fresh launches. When the server resumes a channel,
it submits the prompt and images to that conversation and follows the next turn.
